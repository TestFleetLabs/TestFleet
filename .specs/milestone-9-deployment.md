# TestFleet — Milestone 9: Deployment

## 1. Purpose

Milestone 9 makes TestFleet installable on an internal server as the main spec's amendment describes: **a containerized control plane that orchestrates independently running test containers.** One image, one Compose file, one `.env`. No Elixir on the server.

```text
Internal Server
│
└── Docker Engine
    │
    ├── testfleet            (this image)      ─┐
    ├── db                   (postgres)          ├─ Compose network "backend" (internal)
    ├── docker-socket-proxy  (socket, read-only) ─┘
    │
    └── TestFleet-run-<id>   (created per run, network "TestFleet-runs")
```

The main spec defines the deployment model (section 51, and the amendment "TestFleet Containerized Deployment"). This document records what the amendment leaves open, and where the implementation deviates.

---

## 2. Scope

### In scope

- A production image built from a Mix release
- Migrations on start
- A health endpoint
- A production Compose file with an `.env` template
- Hardening of the TestFleet container
- CI: build the image and boot it with the production Compose file
- Publishing the image to GHCR, versioned by git tags
- Install and upgrade notes

### Out of scope

| What | Milestone |
|------|-----------|
| Docker Hub (`linux/arm64` images were added later, section 10) | later |
| Release automation (changelog, GitHub releases) | later |
| TLS inside TestFleet (it runs behind a reverse proxy, section 6) | – |
| Authentication | later (main spec section 52, milestone 1) |
| Multiple TestFleet nodes | later (main spec section 34) |
| Backups beyond documenting what to back up | – |

---

## 3. Image

Generated with `mix phx.gen.release --docker` and adapted. Two stages on the same Debian release:

- **builder:** `hexpm/elixir` with the versions of `.tool-versions`; compiles the release with minified, digested assets.
- **runner:** `debian:<same>-slim` with the release only, plus `curl` for the health check. Runs as `nobody`.

The image contains Erlang, the release, and compiled assets. It does not contain PostgreSQL, test suite images, browsers, or test code (amendment, "TestFleet Image").

`/app/artifacts` exists in the image, owned by `nobody`, so a named volume mounted there is writable without further setup.

---

## 4. Start

The image's command is `/app/bin/start`: it runs `bin/migrate`, then `exec`s `bin/server`. A failing migration stops the container before the application starts; Compose restarts it, and the logs show the migration error.

This covers the amendment's upgrade order (pull, stop, start, migrate, run): `docker compose pull && docker compose up -d`. Migrations run while no other TestFleet is running, because there is only one.

Stopping the container is safe at any time. Running containers keep running; the reconciler reattaches them on the next start (Milestone 7, section 4). Deadlines come from the persisted `started_at`, so time spent down counts against the run's timeout.

`init: true` in Compose gives the BEAM a proper PID 1 that forwards signals and reaps processes.

---

## 5. Health

`GET /health` is answered by a plug in the endpoint, before request logging, so the check every 30 seconds does not fill the log.

| Database | Response |
|----------|----------|
| `SELECT 1` succeeds | `200 {"status": "ok", "docker": "reachable" \| "unreachable"}` |
| fails | `503 {"status": "error", "docker": …}` |

Docker reachability is reported, but does not make TestFleet unhealthy: restarting TestFleet does not fix Docker, and the dispatcher already holds runs while Docker is down (Milestone 7, section 7).

---

## 6. HTTP, TLS, and the Reverse Proxy

TestFleet serves plain HTTP on port 4000 and expects a reverse proxy (nginx, Traefik, Caddy) in front of it that terminates TLS and sets `X-Forwarded-Proto`. `force_ssl` stays on (it is compile-time): requests without `X-Forwarded-Proto: https` are redirected, except for `localhost`, so the container's own health check works.

- `PHX_HOST` is the public host name. Links in notifications and the WebSocket origin check use it, with `https` on port 443.
- The port is published on `127.0.0.1:4000` by default (`TESTFLEET_PUBLISH`), for a proxy on the same host. A proxy elsewhere publishes it on an interface it can reach.
- The proxy must pass WebSocket upgrades on `/live`.

---

## 7. Compose

`deploy/compose.yaml`, with `deploy/.env.example`. Separate from the development `compose.yaml` in the repository root.

| Service | Image | Networks | Notes |
|---------|-------|----------|-------|
| `testfleet` | `${TESTFLEET_IMAGE:-ghcr.io/testfleetlabs/testfleet:latest}` (section 10) | `backend`, `default` | Waits for a healthy `db`. `default` gives it egress (Slack, webhooks, SMTP) and the published port. |
| `db` | `postgres:18-alpine` | `backend` | Named volume `db`. Health check `pg_isready`. |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | `backend` | Mounts the socket read-only; the only service that does. `CONTAINERS`, `IMAGES`, `NETWORKS`, `AUTH`, `POST` enabled. No published port. |

`backend` is `internal: true`: PostgreSQL and the socket proxy have no route out and no published ports. E2E containers run on `TestFleet-runs`, which TestFleet creates through the Docker API, and cannot reach `backend` (amendment, "Networks").

The socket proxy's endpoints are the ones `Execution.Docker.Command` uses: `_ping`, `version`, `auth`, `containers/*` (create, start, inspect, logs, wait, stop, kill, archive, delete, list), `images/*` (create, inspect, list, delete), `networks/*` (inspect, create).

### Configuration

Set in `.env`:

| Variable | Required | Notes |
|----------|----------|-------|
| `PHX_HOST` | yes | Public host name |
| `SECRET_KEY_BASE` | yes | `openssl rand -base64 48` |
| `CLOAK_KEY` | yes | `openssl rand -base64 32`. **Back it up with the database**; without it, environment variables, registry passwords, and channel URLs are unreadable. |
| `POSTGRES_PASSWORD` | yes | URL-safe, because it is part of `DATABASE_URL`: `openssl rand -hex 24` |
| `TESTFLEET_IMAGE`, `TESTFLEET_PUBLISH` | no | Image and published address |
| everything else in `config/runtime.exs` | no | `MAX_CONCURRENT_RUNS`, `RUN_LOG_LIMIT_MB`, `ARTIFACT_LIMIT_MB`, retention, `PULL_TIMEOUT_SECONDS`, `IMAGE_RETENTION_DAYS`, `SMTP_*`, `HEARTBEAT_URL`, `POOL_SIZE` |

Compose sets `DATABASE_URL`, `DOCKER_HOST=tcp://docker-socket-proxy:2375`, and `ARTIFACTS_DIR=/app/artifacts` itself.

### Artifacts

**Deviation from the amendment:** artifacts live in the named volume `artifacts`, mounted at `/app/artifacts`, instead of the host directory `/var/lib/TestFleet/artifacts`. A named volume takes the ownership of the image's directory, so it works without a `chown` on the host. A host directory still works: mount it at `/app/artifacts` and give it to UID 65534 (`nobody`). The production default of `ARTIFACTS_DIR` changes to `/app/artifacts` accordingly.

### What to back up

The `db` volume (or a `pg_dump`), the `artifacts` volume, and `.env` (above all `CLOAK_KEY`). The TestFleet container holds nothing else.

---

## 8. Hardening

The `testfleet` service runs as `nobody` with `read_only: true`, a `tmpfs` on `/tmp`, `cap_drop: [ALL]`, and `no-new-privileges`. It writes only to `/app/artifacts` and `/tmp`. `RELEASE_TMP=/tmp`, so the release's scripts write there too.

It never mounts the Docker socket; only the proxy does (amendment, "TestFleet → Docker Communication"). As the amendment says, Docker API access remains highly privileged: this is a trusted internal deployment, not an isolation boundary.

---

## 9. CI

A third job, `image`, builds the image (buildx, layers cached in the GitHub Actions cache) and starts `deploy/compose.yaml` with it, generated secrets, and `docker compose up --wait` (which waits for the health checks), then requests `/health` and stops the stack. It is a smoke test: the image builds, the release boots, migrations run on an empty database, and the proxy and networks are wired. It does not execute a run or migrate an existing database.

---

## 10. Publishing

A fourth job, `publish`, pushes the image to `ghcr.io/testfleetlabs/testfleet` (public). It runs on pushes only, never for pull requests, and only after `check`, `docker`, and `image` are green, so a published image has passed every test. It builds from the `image` job's cache, and logs in with `GITHUB_TOKEN` (`packages: write`); no other secret is needed.

| Git ref | Tags |
|---------|------|
| a commit on `main` | `main`, `sha-<short>` |
| the tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<short>` |
| a prerelease tag `v1.3.0-rc.1` | `1.3.0-rc.1`, `sha-<short>` |

- A release tag must match the version in `mix.exs` (`v` + version); otherwise `publish` fails before building.
- `docker/metadata-action` adds the OCI labels, among them `org.opencontainers.image.source`, which links the package to the repository.
- **`linux/amd64` and `linux/arm64`** (added 2026-10-03, for a Raspberry Pi; it was out of scope at first). Each platform builds on a native GitHub runner (`ubuntu-latest`, `ubuntu-24.04-arm`) instead of under QEMU emulation, where compiling the release is slow. `image` smoke-tests both platforms. `publish` pushes each platform by digest from its runner, and a fifth job, `manifest`, puts both digests under the tags with `docker buildx imagetools create`. The arm runners are free for public repositories only.
- The package has to be made public once, in the organization's package settings, after the first push: GHCR creates packages private.

`deploy/compose.yaml` has no `build:`; servers pull. `.env.example` sets `TESTFLEET_IMAGE`, and the README asks to pin a version there, so an upgrade is a deliberate change.

---

## 11. Install and Upgrade

In `deploy/README.md`:

- **Install:** copy `compose.yaml` and `.env.example`, fill `.env` (pinning `TESTFLEET_IMAGE`), `docker compose up -d`, configure the reverse proxy.
- **Upgrade:** set the new version in `TESTFLEET_IMAGE`, `docker compose pull && docker compose up -d`. Running tests survive the restart (section 4).
- **Local image:** `docker build -t testfleet:dev .` and `TESTFLEET_IMAGE=testfleet:dev`.
- **Logs, shell, migrations:** `docker compose logs -f testfleet`; `docker compose exec testfleet bin/testfleet remote`; migrations run on start, `bin/migrate` runs them by hand.
- **Rollback:** the previous image, after rolling back migrations with `bin/testfleet eval 'TestFleet.Release.rollback(TestFleet.Repo, <version>)'` when the new version added any.

---

## 12. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Release and image: `bin/start`, `/health`, the Dockerfile, `.dockerignore`, line endings and executable bits of the scripts, `ARTIFACTS_DIR` default. | – |
| B | Compose, `.env.example`, hardening, `deploy/README.md`, the CI job. | A |
| C | Publishing to GHCR: the `publish` job, the cached build in `image`, Compose pulling instead of building. | B |

Each slice passes `mix precommit` on its own.

**Status (2026-09-30):** all slices are built (483 tests). Locally, the production stack started healthy on an empty database with the hardening of section 8. A run pulled from a private registry passed through it, a run survived `docker compose restart testfleet` with its full log (no gaps, no duplicates), and secrets and artifacts survived `down` and `up`. Next: the CI jobs on GitHub (they run once pushed), making the package public, and a walkthrough behind a real reverse proxy.

Notes:

- The production Compose project is named `testfleet`, like the development one; on a development machine, run it with `-p` and another `TESTFLEET_PUBLISH` (`deploy/README.md`).
- `libsctp1` is in the runner image only to keep OTP's socket module from logging a warning on every start.
- `ERL_CRASH_DUMP=/tmp/erl_crash.dump`, because `/app` is read-only.

---

## 13. Tests

- **`/health`:** `200` with a working database and the Docker status; `HEAD` too; other methods fall through to the router.
- **Image (CI, section 9):** builds, boots on an empty database with the hardening of section 8, and answers `/health`.
- **Publishing (CI, section 10):** a push to `main` publishes `main` and `sha-<short>`; a `v` tag that does not match `mix.exs` fails.

---

## 14. Done

Milestone 9 is done when all slices pass `mix precommit`, the CI jobs are green, the image is public on GHCR, and:

1. `docker compose -f deploy/compose.yaml up -d` with a filled `.env` pulls the published image and starts all three services healthy.
2. Behind a reverse proxy (or with `X-Forwarded-Proto: https`), TestFleet shows the dashboard; live updates work over the WebSocket.
3. A run of the fixture suite passes, its log and artifacts are shown, and the artifacts are in the `artifacts` volume.
4. `docker compose restart testfleet` during a long run: the run continues and finishes after the restart.
5. `docker compose down && docker compose up -d`: projects, runs, secrets, and artifacts are still there.
