# TestFleet — Technical Architecture & Execution Specification

## 1. Overview

**TestFleet** is a self-hosted platform for centrally scheduling, executing, and monitoring automated end-to-end test suites.

The fundamental principle is:

> **Tests belong to the application. Test execution belongs to TestFleet.**

Applications maintain their own E2E test suites alongside their application code. The suite is packaged as a Docker/OCI image.

TestFleet is responsible for:

- configuring test suites
- configuring target environments
- scheduling executions
- starting test containers
- streaming live output
- collecting results
- collecting artifacts
- handling timeouts and cancellation
- maintaining execution history
- sending notifications
- providing a central UI

TestFleet deliberately does **not** become an E2E testing framework.

It does not care whether a test suite uses:

- Playwright
- Cypress
- Selenium
- pytest
- xUnit
- Jest
- custom scripts
- or any other technology

The only requirement is an execution contract based around a container.

---

# 2. Core Product Concept

A project defines:

```text
Project
  ├── Test Definition
  ├── Environment
  └── Schedule
```

A test definition might be:

```text
Customer Portal E2E

Image:
registry.company.com/customer-a/e2e:1.17

Command:
./run-e2e.sh

Timeout:
30 minutes
```

An environment might be:

```text
Production

BASE_URL=https://customer.example.com
API_URL=https://api.example.com
```

A schedule might be:

```text
Every day
06:00
Europe/Vienna
```

TestFleet then executes:

```text
Docker image
    ↓
Environment configuration
    ↓
Container
    ↓
Test execution
    ↓
Logs
    ↓
JUnit results
    ↓
Artifacts
    ↓
Run history
```

---

# 3. Technology Stack

## Application

- Elixir
- Phoenix
- Phoenix LiveView

## Persistence

- PostgreSQL

## Background jobs

- Oban

## Realtime communication

- Phoenix PubSub

## Test execution

- Docker

## Container registry

Any OCI-compatible registry, including:

- GitLab Container Registry
- GitHub Container Registry
- Docker Hub
- Amazon ECR
- private registries

## Artifact storage

MVP:

- local filesystem

Future:

- S3
- MinIO
- other object storage

## Deployment

MVP:

- Docker Compose
- single internal server

Future:

- multiple execution nodes
- Kubernetes
- ECS
- dedicated runner pools

---

# 4. High-Level Architecture

```text
                         ┌─────────────────────┐
                         │      Browser        │
                         └──────────┬──────────┘
                                    │
                                    ▼
                         ┌─────────────────────┐
                         │      Phoenix        │
                         │                     │
                         │ LiveView            │
                         │ Web/API             │
                         │ Domain logic        │
                         └──┬───────┬──────┬───┘
                            │       │      │
              ┌─────────────┘       │      └──────────────┐
              ▼                     ▼                     ▼
        PostgreSQL                Oban           Execution.Dispatcher
                                    │                     │
                                    │                     ▼
                         Schedules.TickWorker   Execution.Supervisor
                         CleanupWorker                    │
                         NotificationWorker               ▼
                                                    RunExecution
                                                          │
                                                          ▼
                                                  Docker Engine API
                                                          │
                                                          ▼
                                                    E2E Container
```

Oban handles time-based and fire-and-forget work. The `Execution.Dispatcher` decides *when a queued run may start* (section 34). Neither Oban nor the dispatcher owns a running container; `RunExecution` does.

Realtime execution output flows through:

```text
Docker
  ↓
Execution process
  ↓
PostgreSQL
  ↓
Phoenix PubSub
  ↓
LiveView
  ↓
Browser
```

PostgreSQL remains the source of truth.

PubSub is the realtime transport layer.

---

# 5. Domain Contexts

The Phoenix application should be divided into clear contexts.

```text
TestFleet.Projects
TestFleet.Environments
TestFleet.TestDefinitions
TestFleet.Schedules
TestFleet.Runs
TestFleet.Results
TestFleet.Artifacts
TestFleet.Execution
TestFleet.Notifications
TestFleet.Accounts
```

The execution subsystem should remain relatively isolated from the UI and domain-specific test configuration.

---

# 6. Database Model

## projects

```text
id
name
slug
description
inserted_at
updated_at
```

---

## test_definitions

```text
id
project_id
name
slug
description

image
command

timeout_seconds

cpu_limit
memory_limit
shm_size_bytes

enabled

inserted_at
updated_at
```

Example:

```text
image = registry.company.com/customer-a/e2e:1.17
command = ["./run-e2e.sh"]
timeout_seconds = 1800
cpu_limit = 2
memory_limit = 4294967296
shm_size_bytes = 2147483648
```

`command` is an **argv array**, not a shell string. TestFleet never parses shell syntax. If a suite needs a shell, it configures `["sh", "-c", "..."]` explicitly.

`command` is **optional**. When empty, the image's own `ENTRYPOINT`/`CMD` is used. This is the recommended setup: the image knows how to run its own suite.

`shm_size_bytes` defaults to 2 GB. Chromium-based browsers (Playwright, Cypress, Puppeteer) crash under Docker's default 64 MB `/dev/shm`.

---

## registries

```text
id
name
host
username
password_encrypted

inserted_at
updated_at
```

Example:

```text
host = registry.company.com
username = TestFleet-deploy-token
```

Registry credentials are resolved by matching the image host against `registries.host`. Credentials are therefore configured once per registry, not per test definition. Images whose host has no matching registry are pulled anonymously.

See section 38.

---

## environments

```text
id
project_id
name
slug
description

max_concurrent_runs

inserted_at
updated_at
```

Environments belong to a project. `max_concurrent_runs` therefore limits concurrency against *this project's* environment (for example the Customer Portal production system), not against all production systems. See section 34.

---

## environment_variables

```text
id
environment_id
key
value_encrypted
secret

inserted_at
updated_at
```

All values are encrypted at rest (for example with `cloak_ecto`), not only secrets.

Secrets must never be returned to the browser after creation.

Keys prefixed with `TestFleet_` are reserved and rejected. See section 12.

---

## schedules

```text
id
test_definition_id
environment_id

cron_expression
timezone

next_run_at
overlap_policy

enabled

inserted_at
updated_at
```

Example:

```text
cron_expression = 0 6 * * *
timezone = Europe/Vienna
next_run_at = 2026-09-27 04:00:00 UTC
overlap_policy = skip
```

`next_run_at` is stored in UTC. It is computed from `cron_expression` in the schedule's `timezone` and recomputed whenever a schedule is created, edited, or re-enabled. See section 28.

`overlap_policy` defines what happens when the schedule fires while its previous run is still `queued`, `preparing`, or `running`:

```text
skip   → no new run is started; the skipped tick is logged (default)
queue  → a new run is queued and waits
allow  → runs may execute in parallel
```

Schedules have minute-level precision.

---

# 7. Runs

Every execution creates an immutable run record.

```text
runs

id

test_definition_id
environment_id

trigger
schedule_id
scheduled_for
triggered_by_user_id

status

image
image_digest
command

container_id
last_log_timestamp

queued_at
started_at
finished_at

exit_code
oom_killed
error_message

inserted_at
updated_at
```

`trigger` records why the run exists:

```text
manual    → "Run now" in the UI (triggered_by_user_id is set)
schedule  → created by the schedule tick (schedule_id and scheduled_for are set)
api       → created through the API (triggered_by_user_id is the token owner)
```

A unique index on `(schedule_id, scheduled_for)` guarantees a schedule never creates two runs for the same slot.

`container_id` and `last_log_timestamp` allow a restarted TestFleet to reattach to a running container and resume log streaming without gaps or duplicates. See section 32.

The run stores the exact image information used for that execution.

This is important for reproducibility.

Avoid relying on:

```text
latest
```

Prefer:

```text
e2e:1.17
```

or, even better:

```text
e2e@sha256:...
```

The run should retain the resolved digest even when a tag was originally configured.

---

# 8. Run Statuses

Supported states:

```text
queued
preparing
running
passed
failed
cancelled
timeout
error
```

Definitions:

### queued

The run has been created but execution has not started.

### preparing

TestFleet is preparing the execution environment, pulling the image, creating the container, etc.

### running

The container is actively executing.

### passed

The test suite completed successfully.

### failed

The test suite executed but one or more tests failed.

### cancelled

The user or system explicitly cancelled execution.

### timeout

The configured maximum execution duration was exceeded.

### error

TestFleet could not successfully execute the test suite.

Examples:

- registry unavailable
- image unavailable
- Docker unavailable
- container could not start
- execution infrastructure failure

This distinction between `failed` and `error` is important.

---

# 9. Run Logs

```text
run_logs

id
run_id

stream
sequence
content
timestamp
```

`stream`:

```text
stdout
stderr
```

`sequence` provides ordering.

`timestamp` is Docker's own log timestamp (nanosecond precision), not TestFleet's receive time. It is what allows resuming a log stream after a restart. See section 32.

One row represents one line. Docker log frames are not line-aligned, so the execution process buffers partial lines and splits on newlines itself.

The database therefore contains the complete historical log, up to the per-run log limit (section 45).

PubSub is only responsible for delivering new output to connected clients.

---

# 10. Test Results

Test suites can optionally produce JUnit XML.

TestFleet parses this into:

```text
test_results

id
run_id

suite
name
classname

status
duration_ms

failure_message
failure_details

inserted_at
updated_at
```

This gives TestFleet a framework-independent structured result format.

A test's identity across runs is `(test_definition_id, suite, classname, name)`. This combination is indexed so per-test history and flakiness (a test alternating between passed and failed without an image change) can be queried later.

TestFleet parses every `*.xml` file directly under `/TestFleet/artifacts/junit/`, plus `/TestFleet/artifacts/junit.xml` if present. Sharded suites therefore produce one file per shard.

Example:

```text
Run #1842

42 passed
2 failed
0 skipped

Duration: 4m 17s
```

---

# 11. Artifacts

```text
artifacts

id
run_id

name
content_type
size_bytes

storage_backend
storage_key

inserted_at
updated_at
```

Artifacts may include:

```text
junit.xml
screenshots
videos
Playwright traces
HTML reports
logs
coverage reports
```

---

# 12. Container Contract

This is the complete contract between TestFleet and a test suite image. It is the only thing application teams need to follow.

## Input

Configuration arrives exclusively through environment variables: the environment's variables, plus these reserved variables injected by TestFleet:

```text
TestFleet_RUN_ID          1842
TestFleet_ENVIRONMENT     production
TestFleet_ARTIFACTS_DIR   /TestFleet/artifacts
```

The `TestFleet_` prefix is reserved and cannot be set by users.

The image must not require interactive input, mounted files, or build-time secrets.

## Execution

- The image starts its suite through its `ENTRYPOINT`/`CMD`, or through the configured `command`.
- The suite must finish within the configured timeout.
- On `SIGTERM` the suite should exit promptly; TestFleet sends `SIGKILL` after a grace period (section 25).

## Output

- **Exit code:** `0` means all tests passed; any other code means failure. See section 24 for how the exit code combines with other signals.
- **Logs:** written to stdout/stderr.
- **Structured results (optional, strongly recommended):** JUnit XML (section 10).
- **Artifacts (optional):** any files under `/TestFleet/artifacts/`.

For example:

```text
/TestFleet/artifacts/
├── junit.xml
├── screenshot-login.png
├── screenshot-checkout.png
└── playwright-report/
```

The directory must be writable by the user the image runs as. Images should create it in their Dockerfile with the correct ownership.

A missing or empty artifacts directory is not an error. The run simply has no artifacts and no structured results.

## Collection

After the container exits, TestFleet copies this directory out of the stopped container (as a tar stream through the Docker Engine API).

The total artifact size per run is limited (configurable, for example 500 MB). When the limit is exceeded, TestFleet keeps the JUnit files, discards the rest, and records a warning on the run.

MVP storage:

```text
/var/lib/TestFleet/artifacts/<run_id>/
```

Future versions can store artifacts in S3-compatible object storage.

---

# 13. Execution Architecture

The execution subsystem is intentionally separated from Oban.

```text
Run created (status = queued)
  │
  ▼
Execution.Dispatcher        ← admission control (section 34)
  │
  ▼
Execution.Supervisor
  │
  ├── RunExecution #1842
  ├── RunExecution #1843
  └── RunExecution #1844
```

The important principle is:

> **Oban decides when a run is created. The dispatcher decides when it may start. The execution subsystem owns the lifecycle of the running container.**

Runs are not started through an Oban job. An Oban job that only calls `Execution.start/1` returns immediately and frees its queue slot while the container keeps running, so Oban's queue limits would not limit containers at all. Blocking the job until the container exits would fix the limit, but would tie the job's lifetime to the container and let Oban's orphan rescue start the same run twice after a crash.

---

# 14. Execution Engine Behaviour

Define a generic execution interface:

```elixir
defmodule TestFleet.Execution.Engine do
  @callback execute(TestFleet.Execution.Request.t()) ::
              {:ok, TestFleet.Execution.Result.t()}
              | {:error, term()}

  @callback cancel(run_id :: integer()) ::
              :ok | {:error, term()}
end
```

The request contains:

```elixir
defmodule TestFleet.Execution.Request do
  defstruct [
    :run_id,
    :project_id,
    :environment_name,
    :image,
    :pull_policy,
    :command,
    :environment,
    :timeout_seconds,
    :stop_grace_seconds,
    :cpu_limit,
    :memory_limit,
    :shm_size,
    :registry_auth,
    :secret_values,
    :artifact_path
  ]
end
```

`pull_policy` defaults to `auto` (section 39); `if_missing` and `never` exist for locally built images. `project_id` and `environment_name` feed the container labels and `TestFleet_ENVIRONMENT`. The execution spike implemented this struct in [execution-spike-spec.md](execution-spike-spec.md).

MVP implementation:

```text
TestFleet.Execution.Docker
```

Future implementations:

```text
TestFleet.Execution.Docker
TestFleet.Execution.ECS
TestFleet.Execution.Kubernetes
```

This means the rest of TestFleet does not need to know how execution infrastructure works.

---

# 15. Docker Execution Lifecycle

A run follows this lifecycle:

```text
resolve image
      ↓
authenticate registry
      ↓
pull image
      ↓
create container
      ↓
start container
      ↓
stream logs
      ↓
wait for exit
      ↓
collect exit code
      ↓
collect artifacts
      ↓
parse results
      ↓
finalize run
      ↓
remove container
```

The individual Docker operations should be separated rather than hiding everything behind one `docker run` command.

Containers are **not** created with `AutoRemove` (`--rm`). The exit code, the `OOMKilled` flag, and the artifacts must be read from the stopped container before TestFleet removes it.

---

# 16. Docker Container Naming

Containers should have deterministic names:

```text
TestFleet-run-1842
```

Labels should also be applied:

```text
TestFleet=true
TestFleet.run_id=1842
TestFleet.project_id=12
```

Labels are essential for:

- cleanup
- recovery
- reconciliation
- debugging
- identifying containers belonging to TestFleet

---

# 17. Docker Resource Limits

Each test definition can optionally define:

```text
CPU limit
Memory limit
Timeout
```

Example:

```text
CPU: 2
Memory: 4 GB
Timeout: 30 minutes
```

The execution engine translates these into Docker resource constraints.

This prevents a single badly behaved test suite from consuming unlimited resources.

---

# 18. Docker Command Abstraction

The Docker implementation should have a small internal abstraction:

```text
TestFleet.Execution.Docker.Command

create(...)
start(...)
logs(...)
wait(...)
stop(...)
kill(...)
cp(...)
remove(...)
inspect(...)
```

The execution subsystem should not scatter raw Docker commands throughout the application.

This makes it easier to:

- test
- mock Docker during tests
- swap the transport

## Docker Engine API, not the Docker CLI

The MVP implementation talks to the **Docker Engine HTTP API** directly (for example with Req/Finch), rather than shelling out to the `docker` CLI. The endpoint comes from `DOCKER_HOST`: the socket proxy in the deployed setup, or the Unix socket in local development (see the Containerized Deployment amendment).

Reasons:

- **Per-request registry authentication.** A pull passes credentials in the `X-Registry-Auth` header. The CLI's `docker login` writes one global config file, which causes races when concurrent runs pull from different registries.
- **Structured errors.** The API returns status codes and JSON error bodies. TestFleet needs these to tell `error` apart from `failed` reliably; parsing CLI stderr is brittle.
- **No CLI dependency.** The TestFleet image does not need to ship the `docker` binary.
- **Streaming.** Logs, pull progress, and `wait` are HTTP streams that map naturally onto an Elixir process.

The cost is handling Docker's multiplexed log stream: when a container runs without a TTY, every frame has an 8-byte header indicating stdout/stderr and the payload length. `Command.logs/2` demultiplexes this and emits `{stream, bytes}` chunks.

Containers are created with `Tty: false` so stdout and stderr stay separable.

All requests use a pinned API version prefix (`/v1.44`, Docker Engine 25+). `DOCKER_HOST` supports `tcp://` and `unix://`. Windows named pipes are not supported by Req, so development on Windows goes through the socket proxy from `compose.yaml` as well.

---

# 19. Docker Container Creation

Conceptually:

```bash
docker create \
  --name TestFleet-run-1842 \
  --label TestFleet=true \
  --label TestFleet.run_id=1842 \
  --label TestFleet.project_id=12 \
  --memory=4g \
  --cpus=2 \
  --shm-size=2g \
  --network=TestFleet-runs \
  --security-opt=no-new-privileges \
  --cap-drop=ALL \
  --env BASE_URL=https://example.com \
  --env TestFleet_RUN_ID=1842 \
  registry.company.com/customer-a/e2e:1.17 \
  ./run-e2e.sh
```

(The implementation uses the equivalent Engine API call, see section 18.)

`MemorySwap` is set equal to `Memory`. Otherwise Docker allows as much swap again, and a suite over its memory limit swaps instead of being OOM-killed.

Two more labels are stored: `TestFleet.timeout_seconds` and `TestFleet.stop_grace_seconds`. They let a reattaching process enforce the deadline even before it has loaded the run from the database.

## Network

Test containers run on a dedicated Docker network, `TestFleet-runs`, which is created by TestFleet at startup if missing.

They must **never** join the Docker Compose network that TestFleet and PostgreSQL use. Otherwise any test suite could reach TestFleet's database.

## Hardening

Every test container gets:

- `no-new-privileges`
- all Linux capabilities dropped
- never `--privileged`
- no host mounts, and in particular never the Docker socket

If a specific suite genuinely needs a capability, that becomes an explicit, visible setting on the test definition, not a default.

## Secrets

Secrets are passed as container environment variables and never written into TestFleet's application logs.

Be aware that environment variables are visible to anyone who can run `docker inspect` on the host. For the trusted MVP deployment this is accepted; a future runner can use Docker secrets or tmpfs-mounted files instead.

Secrets printed by the test suite itself are masked before logs are stored (section 21).

---

# 20. Container Start

After creation:

```bash
docker start TestFleet-run-1842
```

The container then runs independently of the Phoenix process.

This is important for resilience.

If Phoenix crashes while a test is running:

```text
Phoenix
   ↓
crash

Docker container
   ↓
continues running
```

TestFleet can later reconcile the container with the database.

---

# 21. Live Log Streaming

Docker output is streamed using the equivalent of:

```bash
docker logs -f TestFleet-run-1842
```

Output is converted into internal events:

```elixir
{:output,
 %{
   stream: :stdout,
   content: "Running test 1...\n"
 }}
```

or:

```elixir
{:output,
 %{
   stream: :stderr,
   content: "WARNING: ...\n"
 }}
```

Each output event is:

1. split into lines
2. masked
3. persisted to `run_logs`
4. broadcast through Phoenix PubSub

## Secret masking

Before anything is persisted or broadcast, every occurrence of a secret value of the run's environment is replaced with:

```text
[MASKED]
```

Test suites regularly echo configuration or print request headers; without masking, secrets end up in the database and the browser.

Very short secret values (for example under 6 characters) cannot be masked reliably and are rejected when a secret is saved.

## Batching

Chatty suites produce thousands of lines per second. Writing and broadcasting line by line would overload PostgreSQL and the LiveView.

The execution process buffers lines and flushes when either:

```text
100 ms have passed
or
500 lines are buffered
```

Each flush is one `insert_all` into `run_logs` and one PubSub broadcast carrying the batch.

A batch is also flushed at 1 MiB of content, because a single line can be up to 1 MB long. See [milestone-4-live-output.md](milestone-4-live-output.md), section 5.

## Log limit

Each run has a maximum stored log size (configurable, for example 50 MB). Beyond it, TestFleet stops persisting lines, stores a single truncation marker, and keeps streaming only the tail to connected clients.

The truncation marker is the flag `runs.log_truncated`, not a row, so `run_logs` holds only container output. See [milestone-4-live-output.md](milestone-4-live-output.md), section 6.

---

# 22. PubSub

Each run has its own topic:

```text
run:<run_id>
```

Example:

```text
run:1842
```

Events include:

```elixir
{:run_created, run}

{:run_updated, run}      # status or recorded facts changed, e.g. running, image digest

{:run_output, [
  %{stream: :stdout, sequence: 42, content: "Running checkout test..."},
  %{stream: :stdout, sequence: 43, content: "✓ Checkout"}
]}

{:run_test_result, result}

{:run_finished, run}
```

Run events carry the whole run, so subscribers need no extra query. They are also broadcast on the global topic `runs`, which the runs list, the dashboard, and the dispatcher subscribe to; `{:run_output, _}` is only broadcast on `run:<id>`. See [milestone-3-manual-execution.md](milestone-3-manual-execution.md), section 4.

---

# 23. LiveView

Run page:

```text
/runs/:id
```

The LiveView:

1. loads the current run from PostgreSQL
2. loads historical logs
3. subscribes to `run:<id>`
4. receives live events
5. updates the UI

Conceptually:

```text
Browser
   │
   ▼
LiveView
   │
   ├── PostgreSQL → historical state
   │
   └── PubSub → realtime state
```

If the browser disconnects, execution continues normally.

When it reconnects, it reloads state from PostgreSQL and resumes receiving events.

---

# 24. Waiting for Container Completion

The execution process waits for the container to exit.

Conceptually:

```text
docker wait TestFleet-run-1842
```

The exit code is then captured.

Example:

```text
0 → successful execution
1 → test failure
```

However, exit code alone does not determine every final TestFleet status.

Infrastructure failures must remain distinguishable from test failures.

## Final Status Decision Table

The final status is decided in this order. The first matching rule wins.

| # | Condition | Status |
|---|-----------|--------|
| 1 | User or system cancelled the run | `cancelled` |
| 2 | Timeout expired | `timeout` |
| 3 | Failure before the container started (registry, pull, create, start) | `error` |
| 4 | Container state `OOMKilled = true` | `error` (message: memory limit exceeded) |
| 5 | Container disappeared while running | `error` |
| 6 | Exit code `0` and JUnit reports failures or errors | `failed` |
| 7 | Exit code `0` | `passed` |
| 8 | Exit code non-zero and JUnit reports at least one failure | `failed` |
| 9 | Exit code non-zero and JUnit present, but no failures reported | `error` (suite crashed outside of tests) |
| 10 | Exit code non-zero and no JUnit | `failed` |

Notes:

- Rule 6 protects against suites that swallow their own exit code.
- Rule 9 catches crashes in setup/teardown, reporters, or the runner itself, which are not test failures.
- Rule 10 is deliberately `failed`, not `error`: without structured results TestFleet cannot tell the difference, and a false "infrastructure error" is worse than a false "test failure".
- Exit codes `137` without `OOMKilled` (killed by TestFleet during timeout or cancellation) are already covered by rules 1 and 2.

---

# 25. Timeout Handling

Every execution has a maximum duration.

Example:

```text
timeout = 1800 seconds
```

The execution process owns the timeout.

When the timeout expires:

```text
running
   ↓
docker stop
   ↓
if necessary:
docker kill
   ↓
timeout
```

The run is finalized as:

```text
status = timeout
```

The timeout must also trigger cleanup.

`docker stop` sends `SIGTERM` and waits a grace period (default 30 seconds) before `SIGKILL`. Artifacts are still collected from a timed-out container; partial screenshots and traces are often the most useful debugging material.

The deadline is always derived from the persisted `started_at`:

```text
deadline = started_at + timeout_seconds
```

never from a fresh in-memory timer. A `RunExecution` process that is restarted or reattached (section 32) therefore enforces the original deadline. If the deadline has already passed when reattaching, the container is stopped immediately.

The image pull is not part of the run timeout. Pulls have their own timeout (section 39).

---

# 26. Cancellation

Users can cancel a running execution:

```text
POST /api/runs/:id/cancel
```

or through the UI.

The execution subsystem receives:

```elixir
:cancel
```

and stops the container.

Cancellation must be idempotent.

Calling cancel multiple times should not corrupt run state.

Final state:

```text
running
   ↓
cancelled
```

---

# 27. Per-Run Process

Each active execution should have its own supervised Elixir process.

Conceptually:

```text
Execution.Supervisor
        │
        ├── RunExecution #1842
        │
        ├── RunExecution #1843
        │
        └── RunExecution #1844
```

A `RunExecution` process owns:

- container ID
- deadline timer (derived from `started_at`, section 25)
- log streaming
- cancellation
- completion
- artifact collection
- cleanup
- final state transition

This is a natural fit for OTP.

`RunExecution` processes are started with `restart: :temporary`. If one crashes, the supervisor does not restart it blindly; the reconciler (section 32) inspects the container and reattaches or finalizes the run. This keeps one recovery path instead of two.

Starting a run is idempotent: the deterministic container name `TestFleet-run-<id>` means a second attempt to create the same container fails with a conflict instead of starting the suite twice. The attempt that gets the conflict must not touch the container, and in particular must not remove it: it belongs to another execution.

---

# 28. Background Jobs and Scheduling

Oban is used for time-based and fire-and-forget work. It does **not** start or own running containers (section 13).

## Schedules.TickWorker

Dynamic, user-defined schedules are implemented with a single static Oban cron entry that runs every minute:

```elixir
{Oban.Plugins.Cron, crontab: [{"* * * * *", TestFleet.Schedules.TickWorker}]}
```

The tick does not ask "does this cron expression match the current minute?". That approach silently loses runs whenever a tick is late or skipped (deploys, restarts, a busy queue). Instead every schedule stores its `next_run_at`, and the tick picks up everything that is due:

```elixir
def perform(_job) do
  now = DateTime.utc_now()

  Repo.transaction(fn ->
    Schedule
    |> where([s], s.enabled and s.next_run_at <= ^now)
    |> lock("FOR UPDATE SKIP LOCKED")
    |> Repo.all()
    |> Enum.each(fn schedule ->
      Runs.create_scheduled(schedule, scheduled_for: schedule.next_run_at)
      Schedules.advance(schedule, now)
    end)
  end)
end
```

Rules:

- **Missed slots are coalesced.** `Schedules.advance/2` moves `next_run_at` to the first occurrence *after `now`*, not after the old `next_run_at`. After three hours of downtime a twice-daily schedule creates one run, not a burst of catch-up runs.
- **Duplicates are impossible.** `SKIP LOCKED` makes the tick safe with multiple nodes (Oban's cron plugin also only fires on the leader), and the unique index on `runs(schedule_id, scheduled_for)` is the final safeguard.
- **Timezones and DST.** The next occurrence is computed in the schedule's timezone (for example with the `crontab` library on `NaiveDateTime`) and converted to UTC with a timezone database (`tz` or `tzdata`). A local time that does not exist (spring forward) moves to the next valid minute. A local time that occurs twice (fall back) uses the first occurrence.
- **`next_run_at` is recomputed** whenever a schedule is created, edited, or re-enabled, so a changed cron expression takes effect immediately.
- **Overlap policy** (section 6) is evaluated inside `Runs.create_scheduled/2`.

This keeps scheduling on Oban OSS; Oban Pro's `DynamicCron` is not required.

---

## CleanupWorker

Responsible for periodic cleanup and orphan detection, and for enforcing retention (section 46).

---

## NotificationWorker

Responsible for:

- email
- Slack
- Teams
- webhooks

in future versions.

---

## Oban settings

- All Oban workers that create runs use `max_attempts: 1`. Oban's default of 20 attempts contradicts the retry policy (section 35).
- **The reconciler owns crash recovery of runs, not Oban.** Oban's Lifeline plugin may rescue TestFleet's own background jobs, but never re-executes a run.

---

# 29. Manual, Scheduled, and API Runs

Manual, scheduled, and API executions must converge on exactly the same execution pipeline.

Manual:

```text
Run now
  ↓
create Run (queued)
  ↓
Execution.Dispatcher
  ↓
RunExecution
```

Scheduled:

```text
Schedules.TickWorker
  ↓
create Run (queued)
  ↓
Execution.Dispatcher
  ↓
RunExecution
```

API:

```text
POST /api/projects/:project/runs
  ↓
create Run (queued)
  ↓
Execution.Dispatcher
  ↓
RunExecution
```

The only difference between them is the run's `trigger` field.

There should not be separate execution implementations.

---

# 30. Cleanup

Cleanup must happen regardless of how execution terminates.

Conceptually:

```elixir
try do
  execute_run(request)
after
  cleanup_container(container_id)
end
```

Cleanup must be idempotent.

`try/after` (or `terminate/2`) is a best effort only. It does not run when the BEAM is killed, the TestFleet container is stopped hard, or a process is killed brutally. **The reconciler (section 32) is the actual guarantee** that every container is eventually cleaned up.

`RunExecution` does **not** remove its container when the process itself crashes. The suite may still be running and can be reattached; removing it on crash would turn a recoverable situation into a lost run. The normal lifecycle removes the container; after a crash, reconciliation does.

Possible states include:

```text
container created
container started
container crashed
container timed out
Phoenix crashed
Docker failed
user cancelled
```

The system should always attempt to remove the container once it is no longer needed.

---

# 31. Execution Recovery

TestFleet must not assume Phoenix stays alive for the entire execution.

Docker containers exist independently.

Therefore TestFleet needs reconciliation.

---

# 32. Execution Reconciler

Introduce:

```text
TestFleet.Execution.Reconciler
```

At application startup and periodically thereafter, it examines:

```text
Docker containers with:
TestFleet=true
```

and compares them against PostgreSQL.

Example:

```text
Database:

Run #1842
status = running
```

Docker:

```text
TestFleet-run-1842
status = exited
exit_code = 1
```

The reconciler can complete the run.

Other situations:

```text
Database: running
Docker: container missing
```

This should become an infrastructure error after appropriate reconciliation logic.

## Reconciliation Rules

| Database status | Docker container | Action |
|-----------------|------------------|--------|
| `running` / `preparing` | running, no `RunExecution` process | Reattach: start a `RunExecution` in attach mode |
| `running` | exited | Collect exit code, `OOMKilled`, artifacts, and remaining logs; finalize (section 24); remove container |
| `running` / `preparing` | missing | Finalize as `error` ("container disappeared") |
| `queued` | missing | Nothing; the dispatcher will start it |
| finished (`passed`, `failed`, …) | still present | Remove container |
| no run row | labelled `TestFleet=true` | Orphan: stop and remove, log a warning |

A `preparing` run whose container is missing may simply not have been created yet. It is only finalized as `error` when it has been `preparing` for longer than the pull timeout (section 39).

## Reattaching

When reattaching to a running container, `RunExecution`:

1. resumes the log stream with `since = runs.last_log_timestamp` and discards lines whose Docker timestamp is not newer than the last stored one, so no lines are lost or duplicated
2. continues numbering `sequence` from the highest stored value
3. arms the deadline from `started_at` (section 25); if it has already passed, stops the container immediately
4. continues the normal lifecycle (wait, collect, finalize, remove)

`runs.last_log_timestamp` is updated with every log batch flush.

---

# 33. Application Crash Scenario

Example:

```text
Run #1842
     ↓
container starts
     ↓
Phoenix crashes
     ↓
container continues running
     ↓
Phoenix restarts
     ↓
Reconciler finds container
     ↓
execution state restored
```

This is one of the reasons the execution subsystem should be designed around independently identifiable Docker containers.

---

# 34. Concurrency

TestFleet must limit concurrent executions.

Example:

```text
Global concurrency
        │
        ├── maximum 10 containers
        │
        └── environment limits (environments.max_concurrent_runs)
                │
                ├── Customer Portal / production: 2
                ├── Customer Portal / staging: 5
                └── Billing App / production: 1
```

The global limit is application configuration. Environment limits are stored per environment. Because environments belong to a project, a limit protects one application's environment, not every "production" across projects.

## Admission Control

Limits are enforced by `TestFleet.Execution.Dispatcher`, a single process that admits queued runs:

```text
run created (queued) / run finished / every 5 seconds
        ↓
load queued runs, oldest first
        ↓
for each run:
    global running < global limit
    and environment running < environment limit
        → start RunExecution
    otherwise
        → leave queued
```

Rules:

- "Running" counts runs in `preparing` and `running`, read from PostgreSQL, so the count survives restarts.
- A run blocked by its environment limit does not block runs for other environments (no head-of-line blocking).
- The dispatcher is woken by PubSub on run creation and run completion; the 5-second poll is only a safety net.
- In a future multi-node or multi-runner setup, the dispatcher runs once per cluster (for example as a globally registered process, or with a PostgreSQL advisory lock).

Oban queue limits cannot provide this (section 13), and per-key limits are an Oban Pro feature.

The actual limits should be configurable.

The objective is to prevent E2E tests from overwhelming:

- the execution server
- browsers
- target applications
- databases
- production environments
- network infrastructure

---

# 35. Retry Policy

Failed E2E executions should **not** automatically retry by default.

Otherwise flaky tests can become hidden.

Initial policy:

```text
max_attempts = 1
```

If retries are introduced later, each attempt must be visible:

```text
Run #1842

Attempt 1 → failed
Attempt 2 → passed
```

The history should never hide the original failure.

---

# 36. Security Model

The execution subsystem is privileged.

A test container may potentially:

- access internal networks
- access production systems
- consume significant CPU/memory
- execute arbitrary code
- access credentials supplied to it

Therefore:

- registry credentials must be protected
- secrets must be separated from ordinary environment variables
- containers should have resource limits
- execution timeouts are mandatory
- network access should eventually be configurable
- containers must be cleaned up
- TestFleet authentication should be required
- RBAC should be introduced before exposing TestFleet broadly

Concretely, the MVP implements:

- **Encryption at rest** for environment variable values and registry passwords (section 6).
- **Secret masking** in stored and streamed logs (section 21).
- **An isolated run network**, so test containers cannot reach TestFleet's PostgreSQL (section 19).
- **Container hardening:** `no-new-privileges`, all capabilities dropped, never privileged, no host mounts (section 19).
- **A Docker socket proxy** (for example `tecnativa/docker-socket-proxy`) between TestFleet and the Docker socket, allowing only the endpoints TestFleet uses: containers, images, networks. Access to the raw socket is equivalent to root on the host; the proxy narrows what a compromised TestFleet process could do.
- **Single sign-on.** Internal users are expected to log in with the company identity provider through OIDC, rather than with separate TestFleet passwords.
- **API tokens** per user for CI integrations (section 40); tokens are stored hashed and can be revoked.

Known accepted limitation for the MVP: secrets are visible to anyone with `docker inspect` access on the host.

The Docker socket must **not** be exposed directly to arbitrary application code.

For the initial trusted internal deployment, Phoenix may communicate with the local Docker Engine, but the architecture should preserve the option to move execution into a separate runner.

---

# 37. Control Plane vs Execution Plane

MVP:

```text
┌─────────────────────────────┐
│       TestFleet Server      │
│                             │
│ Phoenix                     │
│ PostgreSQL                  │
│ Oban                        │
│ Docker                      │
└─────────────────────────────┘
```

Future architecture:

```text
                 TestFleet
                Control Plane
                     │
                     │
              Runner Protocol
                     │
        ┌────────────┼────────────┐
        ▼            ▼            ▼
     Runner 1     Runner 2     Runner 3
        │            │            │
     Docker       Docker       Docker
```

This allows TestFleet to evolve into a distributed execution platform without changing the core product model.

---

# 38. Registry Support

TestFleet should not assume a specific registry.

A test definition stores:

```text
registry.company.com/customer-a/e2e:1.17
```

The execution engine resolves the image.

Registry configuration is centrally managed in the `registries` table (section 6). Credentials are matched by the image's host, so they are not duplicated across test definitions.

Authentication happens per pull through the Engine API's `X-Registry-Auth` header (section 18). TestFleet never runs `docker login` and never writes a Docker config file.

The MVP supports username/password and token authentication, which covers:

- GitLab (deploy tokens)
- GitHub (personal access tokens)
- Docker Hub
- private OCI registries

Future registry support:

- Amazon ECR, whose tokens expire after 12 hours and must be fetched from AWS before each pull

In the UI, a registry offers a "Test connection" action that authenticates without pulling.

---

# 39. Image Reproducibility

Users may configure:

```text
e2e:1.17
```

but the actual execution should record:

```text
e2e:1.17
digest:
sha256:abc123...
```

This means historical runs remain reproducible even if a mutable tag is later changed.

Preferred configuration:

```text
image@sha256:...
```

when exact reproducibility is required.

## Pull Policy

```text
image referenced by digest  → pull only if not present locally
image referenced by tag     → always pull, so a moved tag is picked up
```

The digest is read from the local image after the pull and stored in `runs.image_digest`.

Mutable tags such as `e2e-latest` are allowed. This is a common and convenient pattern: the application's pipeline pushes the tag, and the next scheduled run picks it up. The recorded digest keeps these runs traceable.

## Pull Timeout

Image pulls have their own timeout (configurable, default 10 minutes), separate from the run's timeout. A pull that exceeds it finalizes the run as `error`.

## Concurrent Pulls

When several runs need the same image at once, only one pull is performed; the other runs wait for its result. This is coordinated inside TestFleet, for example with a per-image lock.

## Image Cleanup

Pulled test images accumulate on the host. The `CleanupWorker` periodically removes test images that no enabled test definition references and that have not been used by a run for a configurable period (for example 7 days).

---

# 40. API

A future API can expose:

```text
POST /api/projects/:project/runs
GET  /api/runs/:id
POST /api/runs/:id/cancel
GET  /api/runs/:id/logs
GET  /api/runs/:id/artifacts
```

This allows external CI systems to trigger TestFleet.

Example:

```text
Deployment
    ↓
POST /api/projects/customer-portal/runs
    ↓
TestFleet
    ↓
E2E execution
```

The request body names the test definition and environment:

```json
{
  "test_definition": "customer-portal-e2e",
  "environment": "staging"
}
```

The response returns the run ID immediately; the caller polls `GET /api/runs/:id` if it wants to wait for the result (for example to gate a deployment pipeline).

API requests authenticate with a bearer token (section 36). Runs created through the API have `trigger = api`.

---

# 41. CLI

A future CLI could provide:

```bash
TestFleet run customer-portal production
```

and:

```bash
TestFleet runs customer-portal
```

Potentially:

```bash
TestFleet logs 1842
TestFleet cancel 1842
```

The CLI should consume the same API rather than implement separate execution logic.

---

# 42. UI

## Dashboard

Display:

```text
Running
Passed today
Failed today
Timeouts
Recent runs
Queued runs
Upcoming schedules
Missed schedules
```

"Upcoming schedules" is simply the enabled schedules ordered by `next_run_at`; no cron parsing happens in the UI.

---

## Project page

```text
Customer Portal

Test Definitions
Environments
Schedules
Recent Runs
```

---

## Test Definition

```text
Customer Portal E2E

Image:
registry.company.com/customer-a/e2e:1.17

Command:
./run-e2e.sh

Timeout:
30 minutes

CPU:
2

Memory:
4 GB
```

---

## Environment

```text
Production

BASE_URL
API_URL
AUTH_CLIENT_ID
...
```

Secret values are never displayed after creation.

---

## Run page

The run page should be the central operational view.

```text
Run #1842

Customer Portal E2E
Production

RUNNING

Started:
06:00:03

Duration:
04:17

────────────────────────────────

Live output

[06:00:03] Starting Playwright
[06:00:04] Launching browser
[06:00:05] Login test
[06:00:07] ✓ Login successful
...
```

After completion:

```text
42 passed
2 failed
0 skipped

Artifacts
├── junit.xml
├── screenshots
└── playwright-report
```

---

# 43. Execution Events

The execution subsystem should expose internal events such as:

```elixir
{:run_preparing, run_id}

{:container_created, container_id}

{:run_started, run_id}

{:run_output, output}

{:run_test_result, result}

{:run_cancelled, run_id}

{:run_timeout, run_id}

{:run_finished, result}

{:run_error, reason}
```

These can be consumed by:

- LiveView
- persistence
- notifications
- metrics
- audit logging

---

# 44. Failure Handling

The system must explicitly handle:

### Registry unavailable

```text
preparing → error
```

### Image does not exist

```text
preparing → error
```

### Docker unavailable

```text
preparing → error
```

### Container cannot start

```text
preparing → error
```

### Image pull exceeds pull timeout

```text
preparing → error
```

### Container exceeds memory limit (OOMKilled)

```text
running → error
```

### Test suite fails

```text
running → failed
```

### Test suite hangs

```text
running → timeout
```

### User cancels

```text
running → cancelled
```

### Phoenix crashes

Execution continues and is reconciled later.

### LiveView disconnects

Execution continues normally.

### Database temporarily fails

Execution state must be designed so that the execution process can recover or reconciliation can restore the correct state.

---

# 45. Logging Architecture

Logs should be treated as an append-only event stream.

Example:

```text
sequence  stream   content

1         stdout   Starting tests
2         stdout   Browser launched
3         stdout   Login test
4         stdout   ✓ Login
5         stderr   warning
6         stdout   Checkout test
```

This makes ordering deterministic.

Writes are batched and size-limited per run (section 21).

Future versions may move very large logs to object storage while retaining metadata in PostgreSQL.

---

# 46. Artifact Lifecycle

Artifact flow:

```text
Container
   │
   │ /TestFleet/artifacts/
   ▼
Execution Engine
   │
   ▼
Artifact Storage
   │
   ▼
PostgreSQL metadata
```

The database stores metadata.

The actual binary files should not be stored directly in PostgreSQL.

## Retention

Without retention, videos and traces fill the disk within weeks. Retention is part of the MVP, not a future feature.

Default policy (configurable globally):

```text
artifacts   30 days
run_logs    90 days
runs        kept indefinitely (small; they carry the history)
test_results kept indefinitely (needed for per-test history)
```

Exceptions:

- The artifacts and logs of the **most recent failed run** of each test definition and environment are always kept, regardless of age, so the latest failure can always be investigated.
- A run can be **pinned** manually from the UI, which exempts it from retention.

When artifacts or logs are removed, the run page shows that they expired instead of showing an empty list.

Retention is enforced by the `CleanupWorker` (section 28), in small batches to avoid long-running deletes on `run_logs`. `run_logs` is a good candidate for PostgreSQL partitioning by month once it grows, so retention becomes dropping a partition.

---

# 47. Observability

Future metrics should include:

```text
TestFleet_runs_total
TestFleet_runs_passed
TestFleet_runs_failed
TestFleet_runs_timeout
TestFleet_run_duration_seconds
TestFleet_running_executions
TestFleet_container_errors
```

Potentially:

```text
TestFleet_queue_depth
TestFleet_artifact_size_bytes
```

This can later integrate with Prometheus/Grafana.

---

# 48. Future Notifications

Possible notification targets:

- email
- Slack
- Microsoft Teams
- webhooks

Examples:

```text
Test suite failed
```

or:

```text
Production E2E recovered after previous failure
```

Notifications should be handled asynchronously through Oban.

## Notify on Transitions, Not on Every Run

By default, notifications are sent when the status of a test definition in an environment **changes**:

```text
passed → failed     notify: "Customer Portal E2E is failing on production"
failed → failed     no notification (still failing)
failed → passed     notify: "Customer Portal E2E recovered on production"
any    → error      notify: infrastructure problem (possibly to a different channel)
```

Alerting on every red run trains people to ignore alerts. A reminder for a suite that stays red (for example once per day) can be added as an option.

`error` and `failed` are reported separately: an `error` is TestFleet's or the infrastructure's problem, a `failed` is the application team's.

## Missed Schedule Alerts

If TestFleet itself is down or stuck, nothing runs and therefore nothing fails, so nobody is alerted.

TestFleet therefore detects schedules whose `next_run_at` is overdue by more than a grace period (for example 10 minutes) without a run having been created, and alerts on them. The dashboard shows them as missed schedules.

Detecting that TestFleet is completely down requires an external check: TestFleet can ping a dead man's switch (for example Healthchecks.io, or an existing monitoring system) on every schedule tick, and that external system alerts when the pings stop.

---

# 49. Future Execution Backends

The execution abstraction deliberately allows:

```text
TestFleet.Execution.Docker
TestFleet.Execution.ECS
TestFleet.Execution.Kubernetes
```

The product model does not change.

Only execution infrastructure changes.

For example:

```text
                TestFleet
                    │
             Execution.Engine
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
     Docker        ECS       Kubernetes
```

---

# 50. Future Runner Architecture

Eventually TestFleet can support dedicated runner agents.

```text
                    TestFleet
                   Control Plane
                        │
                 Runner Scheduler
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
       Runner A      Runner B      Runner C
          │             │             │
       Docker         Docker         Docker
```

Each runner could advertise:

```text
capacity
labels
location
network access
available resources
```

This would allow TestFleet to choose an appropriate execution node.

---

# 51. MVP Deployment

The first deployment should remain intentionally simple.

```text
Internal Server

Docker Compose
│
├── TestFleet
├── postgres
├── docker-socket-proxy
└── (host) docker engine
```

The server can provide significant resources, but concurrency should still be explicitly limited.

The MVP does not need:

- Kubernetes
- ECS
- distributed runners
- S3
- complex RBAC
- multi-region execution

Those can come later.

---

# 52. MVP Milestones

## Milestone 1 — Application Skeleton

- Phoenix
- LiveView
- PostgreSQL
- Oban
- authentication (OIDC single sign-on) — **deferred** (2026-09-26): built after the other milestones; until then all pages are open and user references (`runs.triggered_by_user_id`) stay empty
- basic navigation

---

## Milestone 2 — Test Configuration

Implement:

- projects
- registries
- test definitions
- environments
- environment variables (encrypted at rest)
- schedules

---

## Milestone 3 — Manual Execution

Implement:

```text
Run now
```

with:

```text
Run (queued)
  ↓
Execution.Dispatcher (global and environment limits)
  ↓
RunExecution
  ↓
Docker Engine API (authenticated pull, create, start, wait)
  ↓
final status (section 24)
```

Details: [milestone-3-manual-execution.md](milestone-3-manual-execution.md). Cancellation and a startup-only form of recovery are brought forward from Milestone 7, because without them a hanging or orphaned run would block its environment.

---

## Milestone 4 — Live Output

Implement:

```text
Docker
  ↓
RunExecution
  ↓
PubSub
  ↓
LiveView
```

and persist logs, with batching, secret masking, and the per-run log limit.

Details: [milestone-4-live-output.md](milestone-4-live-output.md).

---

## Milestone 5 — Scheduling

Implement:

```text
Schedules.TickWorker (every minute)
  ↓
due schedules (next_run_at <= now)
  ↓
create Run (queued)
  ↓
Execution.Dispatcher
```

including timezone/DST handling, missed-slot coalescing, and overlap policy.

---

## Milestone 6 — Results and Artifacts

Implement:

- JUnit XML
- test results
- screenshots
- videos
- reports
- artifact downloads
- artifact size limit
- retention

---

## Milestone 7 — Reliability

Implement:

- cancellation (built in Milestone 3; hardening here)
- timeout
- cleanup
- reconciliation and reattaching (startup recovery built in Milestone 3; periodic here)
- orphan detection
- Docker failure handling
- image cleanup

---

## Milestone 8 — Notifications

Implement:

- email
- Slack/Teams
- webhooks
- transition-based alerting
- missed schedule alerts

---

# 53. Execution Technical Spike

Before implementing the entire application, build a small standalone proof of concept.

The spike talks to the Docker Engine API directly (section 18) and should prove these seven things:

### 1. Start

Elixir can launch an arbitrary Docker image.

### 2. Stream

stdout/stderr can be streamed continuously into Elixir, demultiplexed and split into lines.

### 3. Timeout

A long-running container can be stopped after the configured timeout.

### 4. Cancellation

An active execution can be cancelled externally.

### 5. Artifacts

Files can be copied from the stopped container.

### 6. Private registry

An image can be pulled from a private registry (for example the GitLab registry) with per-pull credentials, and its digest recorded.

### 7. Reattach

After the Elixir process is killed mid-run, a new process can find the container by name, resume the log stream from the last timestamp without gaps or duplicates, and complete the run.

A successful spike might expose:

```elixir
{:ok, result} =
  TestFleet.Execution.run(%{
    image: "my-e2e-test:latest",
    command: ["./run-tests.sh"],
    environment: %{
      "BASE_URL" => "https://example.com"
    },
    timeout_seconds: 300
  })
```

and return:

```elixir
%TestFleet.Execution.Result{
  status: :passed,
  exit_code: 0,
  logs: [...],
  artifacts: [...]
}
```

Once this works reliably, the remainder of the TestFleet application is primarily product/domain/UI work around the execution engine.

The spike is specified and tracked in [execution-spike-spec.md](execution-spike-spec.md). It was completed on 2026-09-26; see its section 14 for the findings.

---

# 54. Core Architectural Principle

The most important boundary in TestFleet is:

```text
                 WHAT
                  │
                  ▼
             TestFleet
                  │
                  │
                  ▼
                 HOW
                  │
                  ▼
          Execution Engine
                  │
                  ▼
              Container
                  │
                  ▼
               E2E Tests
```

TestFleet knows:

- what test to run
- where to run it
- when to run it
- which image to use
- which configuration to provide
- how long it may run
- what happened
- what artifacts were produced

TestFleet does **not** know:

- how Playwright works
- how Cypress works
- how Selenium works
- how pytest works
- how the tests are structured

That separation is fundamental to keeping TestFleet framework-agnostic.

---

# 55. Product Philosophy

The core proposition can be summarized as:

> **Give TestFleet a Docker image. Tell it where and when to run it. TestFleet takes care of the rest.**

Or, more succinctly:

> **Tests belong to the application. Test execution belongs to TestFleet.**

---

# Amendment — TestFleet Containerized Deployment

## TestFleet Runs as a Docker Container

TestFleet itself is distributed and deployed as a Docker container.

The application should not require a native Elixir/Phoenix installation on the target server.

The initial deployment model is:

```text
Internal Server
│
└── Docker Engine
    │
    ├── TestFleet
    │   ├── Phoenix
    │   ├── LiveView
    │   ├── Oban
    │   └── Execution subsystem
    │
    ├── PostgreSQL
    │
    ├── E2E container
    ├── E2E container
    └── E2E container
```

Docker Compose should be the initial deployment mechanism.

## Docker Compose

The initial installation should consist of:

```text
docker-compose.yml
```

with at least:

```text
TestFleet
postgres
docker-socket-proxy
```

TestFleet connects to PostgreSQL through the Docker Compose network.

The Docker Engine itself remains the host's Docker daemon.

## TestFleet → Docker Communication

For the MVP, TestFleet communicates with the host Docker Engine through a Docker socket proxy:

```text
TestFleet container
        │
        │ HTTP (Docker Engine API), Compose network only
        ▼
docker-socket-proxy container
        │
        │ /var/run/docker.sock (mounted read-only into the proxy only)
        ▼
Host Docker Engine
```

The proxy only allows the API endpoints TestFleet needs (containers, images, networks). Only the proxy mounts the socket; the TestFleet container does not.

The TestFleet container can therefore create and manage E2E containers.

For local development, TestFleet can also talk to the socket directly. The transport is configuration (`DOCKER_HOST`), not code.

## Networks

The Compose file defines the internal network used by TestFleet, PostgreSQL, and the socket proxy.

E2E containers run on the separate `TestFleet-runs` network (section 19) and can never reach PostgreSQL or the socket proxy.

This approach is intentionally limited to the trusted internal deployment model.

Access to the Docker socket is highly privileged and should not be considered a secure isolation boundary for an untrusted multi-tenant installation.

## E2E Containers

E2E containers are separate from the TestFleet application container.

For example:

```text
TestFleet
postgres

TestFleet-run-1842
TestFleet-run-1843
TestFleet-run-1844
```

TestFleet creates and removes these containers dynamically through the Docker Engine.

The E2E containers must never be baked into the TestFleet image.

## TestFleet Image

The TestFleet image should contain:

```text
Elixir
Erlang/OTP
Phoenix application
compiled assets
runtime configuration
```

It should not contain:

* PostgreSQL
* test suite images
* browser dependencies for arbitrary test suites
* customer-specific test code

Those dependencies belong to their respective containers.

## Configuration

Runtime configuration should be supplied through environment variables and/or mounted configuration/secrets.

Examples:

```text
DATABASE_URL
SECRET_KEY_BASE
CLOAK_KEY
PHX_HOST
PORT
DOCKER_HOST
```

`CLOAK_KEY` (base64, 32 bytes) encrypts environment variable values and registry passwords at rest. Losing it makes them unreadable, so it must be backed up with the database.

TestFleet should not require rebuilding its image for environment-specific configuration.

## Persistent Data

The TestFleet application container itself should be considered disposable.

Persistent data must live outside the container:

```text
PostgreSQL
    ↓
persistent volume

Artifacts
    ↓
persistent volume or object storage

TestFleet configuration
    ↓
PostgreSQL
```

The container can therefore be upgraded or replaced without losing application state.

## Artifact Storage

The MVP may use a persistent host-mounted directory:

```text
/var/lib/TestFleet/artifacts
```

mounted into the TestFleet container.

For example:

```text
Host
└── /var/lib/TestFleet/artifacts
        │
        ▼
TestFleet
└── /app/artifacts
```

A future object-storage backend can replace this without changing the execution model.

## Container Upgrade

A TestFleet upgrade should follow the normal Docker deployment model:

```text
pull new TestFleet image
        ↓
stop old container
        ↓
start new container
        ↓
run database migrations
        ↓
application starts
```

PostgreSQL data and artifacts remain outside the application container.

## Future Runner Architecture

The MVP uses:

```text
TestFleet container
        │
        │ Docker Engine API (via socket proxy)
        ▼
Host Docker Engine
```

The architecture must preserve a future migration to:

```text
                    TestFleet
                  Control Plane
                 Docker container
                        │
                        │ Runner API
                        ▼
                 TestFleet Runner
                        │
                        ▼
                  Docker Engine
                        │
             ┌──────────┼──────────┐
             ▼          ▼          ▼
           E2E #1     E2E #2     E2E #3
```

The TestFleet application therefore owns the **control plane**, while the runner owns the **execution plane**.

This allows future deployments to use:

* dedicated runner servers
* multiple Docker hosts
* ECS
* Kubernetes
* isolated execution networks
* runner pools

without changing the core TestFleet domain model.

## Deployment Principle

TestFleet should be:

> **A containerized control plane that orchestrates independently running test containers.**

The TestFleet container is not the test environment.

It manages the test environments.

This distinction should remain fundamental to the architecture.
