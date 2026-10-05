# TestFleet

TestFleet is a self-hosted platform for centrally scheduling, executing, and monitoring automated end-to-end test suites.

> **Tests belong to the application. Test execution belongs to TestFleet.**

Each application keeps its own E2E suite in its own repository and ships it as a Docker/OCI image. TestFleet does not care which framework the suite uses (Playwright, Cypress, Selenium, pytest, Jest, custom scripts, ...). It only requires that the image follows a small container contract. TestFleet then:

- configures test definitions, environments, and schedules per project
- pulls the image (with per-registry credentials) and runs it as an isolated container
- streams live output to the browser, with secrets masked
- collects the exit code, JUnit XML results, and artifacts (screenshots, videos, traces, reports)
- enforces timeouts, cancellation, and concurrency limits
- keeps the run history and applies retention
- sends notifications when a suite starts failing or recovers

The full design lives in [.specs/tech-architecture-execution-spec.md](.specs/tech-architecture-execution-spec.md). The user documentation and the website are in [docs/](docs/) (Astro and Starlight), published at [testfleet.io](https://testfleet.io).

## Core concepts

```text
Organization            members and roles, registries, notification channels, API tokens
  └── Project
        ├── Test Definition   image, optional command, timeout, CPU/memory limits
        ├── Environment       variables and secrets (encrypted at rest), concurrency limit
        └── Schedule          cron expression + timezone, overlap policy
```

A self-hosted installation has exactly one organization; its slug starts every page's URL (`/acme/projects/customer-portal`).

Every execution creates an immutable **run** with one of these statuses: `queued`, `preparing`, `running`, `passed`, `failed`, `cancelled`, `timeout`, `error`. `failed` means the tests failed; `error` means TestFleet or the infrastructure could not run them.

Runs are created manually ("Run now"), by a schedule, or through the API. All three go through the same pipeline:

```text
create Run (queued) → Execution.Dispatcher → RunExecution → Docker Engine API → E2E container
```

## Container contract

This is everything a test suite image needs to follow.

**Input:** configuration arrives only through environment variables: the environment's variables, plus these reserved ones:

```text
TestFleet_RUN_ID          1842
TestFleet_ENVIRONMENT     production
TestFleet_ARTIFACTS_DIR   /TestFleet/artifacts
```

**Execution:** the suite starts through the image's `ENTRYPOINT`/`CMD` (or the configured `command`), finishes within the timeout, and exits promptly on `SIGTERM`.

**Output:**

- exit code `0` means passed, anything else means failed
- logs go to stdout/stderr
- JUnit XML (optional, strongly recommended) at `/TestFleet/artifacts/junit.xml` or `/TestFleet/artifacts/junit/*.xml`
- any other files under `/TestFleet/artifacts/` are collected as artifacts

See section 12 of the spec for details.

## Tech stack

- Elixir, Phoenix, Phoenix LiveView
- PostgreSQL
- Oban for scheduling and background jobs
- Phoenix PubSub for live output
- Docker Engine HTTP API (via Req) for test execution
- Docker Compose for deployment (TestFleet, PostgreSQL, docker-socket-proxy)

## Architecture at a glance

```text
Browser ── LiveView ── Phoenix ──┬── PostgreSQL (source of truth)
                                 ├── Oban (schedule tick, cleanup, notifications)
                                 └── Execution.Dispatcher
                                        └── Execution.Supervisor
                                               └── RunExecution (one process per run)
                                                      └── Docker Engine API → E2E container
```

- Oban decides **when a run is created**, the dispatcher decides **when it may start**, and `RunExecution` owns the **running container**.
- Containers run independently of Phoenix. After a crash or restart, the `Execution.Reconciler` reattaches to running containers or finalizes finished ones.
- Test containers run on a dedicated `TestFleet-runs` network, hardened (`no-new-privileges`, all capabilities dropped), and can never reach TestFleet's database.

## Development

Requirements (see [.tool-versions](.tool-versions)):

- Erlang/OTP 29, Elixir 1.20
- Docker (for PostgreSQL and for running test containers)

Start the local services (PostgreSQL and a Docker socket proxy that exposes a restricted Engine API on `127.0.0.1:2375`):

```bash
docker compose up -d
```

Then set up and run the app:

```bash
mix setup            # install deps, create and migrate the database, build assets
mix phx.server       # or: iex -S mix phx.server
```

Visit [`localhost:4000`](http://localhost:4000). Every page needs a login: on a fresh database, the log shows a one-time link (`No users yet. Create the first admin at …/setup?token=…`) that creates the first admin and names the organization.

To try single sign-on, start the Keycloak development realm (users `alice`/`alice` with a verified email, `bob`/`bob` without) and run TestFleet against it:

```bash
docker compose --profile oidc up -d keycloak
OIDC_ISSUER=http://localhost:8180/realms/testfleet OIDC_CLIENT_ID=testfleet \
  OIDC_CLIENT_SECRET=testfleet-dev-secret mix phx.server
```

Before committing, run:

```bash
mix precommit        # compile with warnings as errors, format, test
```

Tests that drive real containers are tagged `:docker` and excluded by default. They need the fixture suite image, pushed to the fixture registry (section 44 of the spec lists the fixture's modes):

```bash
docker build -t testfleet/fixture-suite:dev test/support/fixtures/suite
docker compose --profile registry up -d registry
docker tag testfleet/fixture-suite:dev localhost:5055/fixture-suite:dev
echo fixture-password | docker login localhost:5055 -u fixture --password-stdin
docker push localhost:5055/fixture-suite:dev
docker logout localhost:5055
DOCKER_HOST=tcp://localhost:2375 mix test --only docker
```

To watch a single container go through the execution engine:

```bash
mix testfleet.try --image testfleet/fixture-suite:dev --env FIXTURE_MODE=chatty
```

## What's next

Planned directions include a CLI on top of the API, remote runners and other execution backends (ECS, Kubernetes), object storage for artifacts, and finer permissions. The roadmap is section 45 of the spec.

## Contributing

Contributions are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Contributors accept the [Contributor License Agreement](CLA.md) once, through a bot comment on their first pull request.

## License

TestFleet is free software under the [GNU Affero General Public License v3.0](LICENSE). You can use, self-host, and modify it; if you offer a modified version to others over a network, you must make its source available to them.
