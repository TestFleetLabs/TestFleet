# Deploying TestFleet

TestFleet runs as three containers on one Docker host: TestFleet itself, PostgreSQL, and a Docker socket proxy. TestFleet starts the test containers on the host's Docker Engine through the proxy. The full guide is at [testfleet.io/operate/install](https://testfleet.io/operate/install/); design and reasoning are in section 43 of the [specification](../.specs/tech-architecture-execution-spec.md).

## Requirements

- Docker Engine with Compose v2.20 or later
- A reverse proxy (nginx, Traefik, Caddy) that terminates TLS, sets `X-Forwarded-Proto`, and passes WebSocket upgrades on `/live`

## Install

The server needs only this directory's `compose.yaml` and `.env.example`; the image comes from `ghcr.io/testfleetlabs/testfleet`.

```sh
mkdir testfleet && cd testfleet
# copy compose.yaml and .env.example here
cp .env.example .env
```

Fill in the four required values in `.env`, and pin `TESTFLEET_IMAGE` to a release:

```sh
openssl rand -base64 48   # SECRET_KEY_BASE
openssl rand -base64 32   # CLOAK_KEY
openssl rand -hex 24      # POSTGRES_PASSWORD
```

Start it:

```sh
docker compose up -d
docker compose ps          # all three healthy
```

Migrations run on every start. TestFleet listens on `127.0.0.1:4000` (`TESTFLEET_PUBLISH`); point the reverse proxy at it:

```nginx
location / {
  proxy_pass http://127.0.0.1:4000;
  proxy_set_header Host $host;
  proxy_set_header X-Forwarded-Proto https;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "upgrade";
}
```

TestFleet redirects plain HTTP requests to HTTPS, except on `localhost`.

### First login

Every page needs a login. While there is no user, TestFleet logs a one-time link on each start:

```sh
docker compose logs testfleet | grep "No users yet"
# No users yet. Create the first admin at https://testfleet.example.internal/setup?token=…
```

Open it to create the first admin; `/setup` without the token does not exist. Everyone else is invited from the Users page: the invitation link is shown to copy, and emailed too when SMTP is configured.

## Single sign-on

TestFleet logs in with one OpenID Connect provider. It is found through the provider's discovery document, so anything that speaks OIDC works. Set the `OIDC_*` variables in `.env` (see `.env.example`) and register `https://<PHX_HOST>/auth/oidc/callback` as the redirect URI at the provider.

**Which issuer?** If another internal application already logs in with the company provider (for example Dependency-Track, with its `ALPINE_OIDC_ISSUER`), its issuer tells you which provider you have:

- `https://login.microsoftonline.com/<tenant-id>/v2.0`: **Entra ID**. Create an app registration: a web platform with the redirect URI above, and a client secret (`OIDC_CLIENT_SECRET`); the application (client) ID is `OIDC_CLIENT_ID`. To let only certain people in, set "Assignment required" on its enterprise application and assign them.
- `https://<adfs-host>/adfs`: **AD FS** (on-premises Active Directory). Create an application group with a server application: the redirect URI above, a client secret, and issuance rules that add the email address.

**Email claim.** TestFleet names users by email. Entra sends `email` only for users with a mailbox or when it is added as an optional claim; otherwise set `OIDC_EMAIL_CLAIM=preferred_username` (the UPN). Users are matched by the provider's subject, not by email, so changing the email later does not create a second account.

**Who gets in.** With `OIDC_USER_PROVISIONING=true` (the default), anyone the provider lets through gets a member account on first login, optionally limited by `OIDC_ALLOWED_DOMAINS`; admins promote them on the Users page. With `false`, only invited users get in. Neither Entra nor AD FS confirms that an email address is verified, so an existing TestFleet account is never taken over by email: invitation links offer "Continue with <provider>", which links the account at the provider.

**SSO button only.** `AUTH_PASSWORD_LOGIN=false` removes password login, like Dependency-Track behind the same provider. The first-run setup link then creates the first admin through the provider too.

## Starting runs from CI

A deployment pipeline can start the E2E suite after it deploys, wait for the result, and fail when the tests fail. The full guide is at [testfleet.io/ci/pipelines](https://testfleet.io/ci/pipelines/); the design is section 38 of the [specification](../.specs/tech-architecture-execution-spec.md).

### A token

Create one in **Settings → API tokens**; it is shown once. A token acts as the user who created it, and stops working when that user is deactivated. So a pipeline does not break when its author leaves, invite a user for it (`ci@example.com`), accept the invitation, and create the token as that user. Store it as a masked secret in the CI system.

### The script

[`ci/testfleet-run.sh`](ci/testfleet-run.sh) (curl and jq) and [`ci/testfleet-run.ps1`](ci/testfleet-run.ps1) (PowerShell 7) do the whole job; copy one into the application's repository:

```sh
export TESTFLEET_URL=https://testfleet.example.internal
export TESTFLEET_TOKEN=tf_…
sh ci/testfleet-run.sh customer-portal e2e staging 1.4.2
```

```text
TestFleet: e2e now uses ghcr.io/acme/portal-e2e:1.4.2
TestFleet: run 1842 of ghcr.io/acme/portal-e2e:1.4.2 on staging
TestFleet: https://testfleet.example.internal/runs/1842
…the suite's output, as it runs…
TestFleet: run 1842 passed (41 passed, 0 failed, 3 skipped)
```

The arguments are the project, test definition, and environment slugs (as in the web UI's URLs), and optionally the E2E image's tag. With a tag, the test definition is updated first, so scheduled runs use the new image from then on too. The exit status is `0` when the run passed, `1` when its tests failed, and `2` for anything else: an infrastructure error, a timeout, a cancelled run, or a refused request.

**One deployment at a time.** If two pipelines update the tag and start a run at the same time, one of them can test the other's image. Let pipelines that deploy the same environment wait for each other (GitHub's `concurrency`, GitLab's `resource_group`), as in the examples below.

### GitHub Actions

GitHub-hosted runners cannot reach an internal TestFleet; use a self-hosted runner in the same network.

```yaml
e2e:
  needs: deploy-staging
  runs-on: [self-hosted]
  concurrency: staging
  steps:
    - uses: actions/checkout@v4
    - run: sh ci/testfleet-run.sh customer-portal e2e staging "${{ github.ref_name }}"
      env:
        TESTFLEET_URL: https://testfleet.example.internal
        TESTFLEET_TOKEN: ${{ secrets.TESTFLEET_TOKEN }}
```

### GitLab CI

```yaml
e2e:staging:
  stage: verify
  needs: ["deploy:staging"]
  resource_group: staging
  image: alpine:3.22
  before_script:
    - apk add --no-cache curl jq
  script:
    - sh ci/testfleet-run.sh customer-portal e2e staging "$CI_COMMIT_TAG"
  variables:
    TESTFLEET_URL: https://testfleet.example.internal
  # TESTFLEET_TOKEN: a masked CI/CD variable
```

### The API

Every request sends `Authorization: Bearer <token>`; request bodies are JSON (`Content-Type: application/json`). Errors look like `{"error": {"code": "not_found", "message": "No environment \"stagign\" in project \"customer-portal\"."}}`, with `details` per field for `422`.

| Method | Path | |
|--------|------|-|
| `POST` | `/api/v1/projects/:project/runs` | Start a run: `{"test_definition": "e2e", "environment": "staging"}`. `201` with the run. |
| `GET` | `/api/v1/runs/:id` | The run: `status`, `final` (no further change), `image`, `exit_code`, `tests` (`passed`, `failed`, `skipped`, or `null` without a JUnit report), `url`, `log_url`, `artifacts_url`. |
| `POST` | `/api/v1/runs/:id/cancel` | Cancel; `202`. An active run is `cancelled` once its container has stopped. |
| `GET` | `/api/v1/runs/:id/log` | The log as text. `?after=<n>` sends only lines after sequence `n`; the `TestFleet-Log-Sequence` header names the last line sent. |
| `GET` | `/api/v1/runs/:id/artifacts` | The artifacts, with download URLs. |
| `GET` | `/api/v1/runs/:id/artifacts/*name` | One artifact's file. |
| `GET` | `/api/v1/projects/:project/test-definitions/:slug` | The test definition and its image. |
| `PATCH` | `/api/v1/projects/:project/test-definitions/:slug` | Update the image: `{"tag": "1.4.2"}` (only the tag) or `{"image": "ghcr.io/acme/portal-e2e:1.4.2"}`. |

A pipeline should pass only on `passed`: `failed` means the tests failed, while `error` and `timeout` mean TestFleet could not tell. The log and artifacts of old runs are removed by retention; they then answer `410`.

## Upgrade

Set the new version in `TESTFLEET_IMAGE`, then:

```sh
docker compose pull
docker compose up -d
```

Migrations run on start. Running tests survive the restart: their containers keep running, and TestFleet picks them up again when it is back. Time spent down counts against their timeout.

## Operate

| Task | Command |
|------|---------|
| Logs | `docker compose logs -f testfleet` |
| Health | `curl http://127.0.0.1:4000/health` |
| Remote shell | `docker compose exec testfleet bin/testfleet remote` |
| Run migrations by hand | `docker compose exec testfleet bin/migrate` |
| Lost admin access | `docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'` prints a link that sets a new password |
| Roll back migrations | `docker compose exec testfleet bin/testfleet eval 'TestFleet.Release.rollback(TestFleet.Repo, 20260930000000)'` |

## Back up

- **`.env`, above all `CLOAK_KEY`.** It encrypts environment variables, registry passwords, and notification URLs; a database restored without it has unreadable secrets.
- The database: `docker compose exec db pg_dump -U testfleet testfleet > testfleet.sql`
- The `testfleet_artifacts` volume (screenshots, videos, reports)

The TestFleet container itself holds nothing; it can be removed and recreated at any time.

## Artifacts on a host directory

Artifacts are kept in a named volume. To keep them in a host directory instead, give it to UID 65534 and mount it at `/app/artifacts`:

```sh
sudo mkdir -p /var/lib/testfleet/artifacts
sudo chown 65534 /var/lib/testfleet/artifacts
```

```yaml
# compose.override.yaml
services:
  testfleet:
    volumes:
      - /var/lib/testfleet/artifacts:/app/artifacts
```

## Images

| Tag | Published for |
|-----|---------------|
| `1.2.3`, `1.2` | the git tag `v1.2.3` |
| `latest` | the newest release (not prereleases like `v1.3.0-rc.1`) |
| `main`, `sha-<commit>` | every commit on `main`, once CI is green |

Every tag holds images for `linux/amd64` and `linux/arm64`; Docker pulls the one that fits the host.

### Raspberry Pi and other ARM hosts

TestFleet runs on a Raspberry Pi 4 or 5 with a 64-bit OS (`uname -m` says `aarch64`); 32-bit Raspberry Pi OS is not supported. The stack itself needs about 1 GB of memory; the test containers need what they always need, so a Pi with 8 GB is a comfortable minimum for browser suites.

The suites run on the same host, so **their images must exist for `linux/arm64` too.** The Playwright images (`mcr.microsoft.com/playwright`) do; your own suite image needs a multi-platform build (`docker buildx build --platform linux/amd64,linux/arm64 …`). An amd64-only image fails the run with an error like "no matching manifest for linux/arm64".

## Trying it on a development machine

Build the image from the repository root:

```sh
docker build -t testfleet:dev .
```

The development `compose.yaml` in the repository root has the same Compose project name (`testfleet`). Give the production stack another one, and another port, so the two do not take over each other's containers:

```sh
cd deploy
TESTFLEET_IMAGE=testfleet:dev TESTFLEET_PUBLISH=127.0.0.1:4100 docker compose -p testfleet-local up -d
```

TestFleet always pulls images, so a suite image has to come from a registry, not only from the local image store.

## Security

The socket proxy only lets TestFleet reach the container, image, network, and registry auth endpoints, and only the proxy mounts the Docker socket. Docker API access is still highly privileged: this setup is for a trusted internal network, not an isolation boundary between tenants.
