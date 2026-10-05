# TestFleet — Technical Architecture & Execution Specification

This document describes TestFleet as it is built, and the decisions behind it. It is the source of truth for names (contexts, tables, fields, statuses, events) and behaviour. A change that deviates from it updates it in the same change.

The user documentation lives in [docs/](../docs/) and is published at [testfleet.io](https://testfleet.io).

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
- providing a central UI and an API for CI

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

The only requirement is an execution contract based around a container (section 12).

---

# 2. Core Product Concept

A project defines:

```text
Project
  ├── Test Definition   image, optional command, timeout, CPU/memory limits
  ├── Environment       variables and secrets, concurrency limit
  └── Schedule          test definition × environment, cron expression, timezone, overlap policy
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

| Concern | Choice |
|---------|--------|
| Application | Elixir, Phoenix, Phoenix LiveView |
| Persistence | PostgreSQL |
| Background jobs | Oban (OSS) |
| Realtime | Phoenix PubSub |
| Test execution | Docker, through the Docker Engine HTTP API (section 18) |
| HTTP client | `Req`, for everything including Docker |
| Encryption at rest | `cloak_ecto` (section 6) |
| Schedules | `crontab` for cron expressions, `tz` as the timezone database |
| Login | `phx.gen.auth` (adapted), `pbkdf2_elixir`, `oidcc` for OIDC (section 35) |
| Email | Swoosh, with `gen_smtp` for SMTP |
| Artifact storage | the local filesystem (a mounted volume) |
| Deployment | one image, Docker Compose, a Docker socket proxy (section 43) |

Container registries: any OCI-compatible registry with username/password or token authentication (section 36).

What later versions may add is collected in the roadmap (section 45).

---

# 4. High-Level Architecture

```text
                         ┌─────────────────────┐
                         │  Browser / CI (API) │
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
                         EvaluateWorker                   ▼
                         DeliveryWorker             RunExecution
                                                          │
                                                          ▼
                                                  Docker Engine API
                                                          │
                                                          ▼
                                                    E2E Container
```

Oban handles time-based and fire-and-forget work. The `Execution.Dispatcher` decides *when a queued run may start* (section 32). Neither Oban nor the dispatcher owns a running container; `RunExecution` does. `Execution.Reconciler` compares PostgreSQL with Docker and repairs what processes failed to finish (section 30).

Realtime execution output flows through:

```text
Docker
  ↓
RunExecution (split into lines, mask, number, batch)
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

```text
TestFleet.Organizations      organizations and memberships
TestFleet.Projects
TestFleet.Environments
TestFleet.TestDefinitions
TestFleet.Registries
TestFleet.Schedules
TestFleet.Runs
TestFleet.Results
TestFleet.Artifacts
TestFleet.Execution
TestFleet.Notifications
TestFleet.Accounts
```

**Execution stays isolated.** `TestFleet.Execution` (`RunExecution`, `Execution.Docker.*`, `Status`, `Masker`, `PullCoordinator`) never touches the `Repo` or the configuration contexts. Everything a run needs arrives in its `Request` (section 14), and everything it produces leaves as events to a handler. The dispatcher and the reconciler are the bridges: they read runs through `TestFleet.Runs`, and `Runs.build_request/1` builds the request. `TestFleet.Results.JUnit` is pure (no database, no configuration), so `RunExecution` can call it.

**Organizations and scopes.** Everything users configure and run belongs to an organization, the tenant (section 35). Context functions that find, list, or create the roots of organization-owned data (projects, registries, notification channels, runs, API tokens, and anything listed across projects, such as the dashboard's figures) take a `TestFleet.Accounts.Scope` as their first argument and only see that organization's data; a record of another organization is "not found". Functions on children take their parent, found through the scope, and only see that parent's children: `Environments.get_environment!(project, slug)`, `Notifications.get_subscription!(channel, id)`, `Artifacts.get_artifact(run, name)`. Background processes (the dispatcher, the reconciler, the schedule tick, retention, cleanup, notification workers) work across organizations through internal functions, which say so in their docs and are never called from the web layer. Roles are enforced with the scope (`Scope.admin?/1`) at the edge.

---

# 6. Configuration Data

## projects

```text
id
organization_id
name
slug
description
inserted_at
updated_at
```

`slug` is unique per organization, used in URLs and in the API. Everything below a project (environments, variables, test definitions, schedules, runs) belongs to the project's organization.

Deleting a project deletes its test definitions, environments, variables, and schedules (`on_delete: :delete_all`), but a project with runs cannot be deleted (section 7).

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

- `slug` is unique per project; the API names test definitions by it.
- `image` is trimmed and validated with `Execution.Docker.ImageRef.parse/1`. The form shows live which registry's credentials a pull will use, or that the image is pulled anonymously.
- `command` is an **argv array**, not a shell string. TestFleet never parses shell syntax; a suite that needs a shell configures `["sh", "-c", "..."]` explicitly. It is **optional**: when empty, the image's own `ENTRYPOINT`/`CMD` is used. This is the recommended setup: the image knows how to run its own suite. At most 100 arguments of at most 4096 characters. The form has one argument per line; lines are trimmed and empty lines dropped.
- `timeout_seconds`: required, default 1800, 1..86400. The form shows whole minutes; a stored value that is not a whole number of minutes is rounded up in the form.
- `cpu_limit`: optional, > 0 and ≤ 256, fractional allowed.
- `memory_limit`: optional, in bytes, at least 6 MiB (Docker's minimum).
- `shm_size_bytes`: required, at least 1 MiB, default 2 GiB. Chromium-based browsers (Playwright, Cypress, Puppeteer) crash under Docker's default 64 MB `/dev/shm`.
- `enabled`: default true. A disabled test definition cannot be run, and its schedules skip (section 27).
- The form's units are virtual fields (`timeout_minutes`, `memory_limit_mib`, `shm_size_mib`, `command_text`); they set the stored fields only when submitted, so the API uses seconds and bytes directly.

---

## registries

```text
id
organization_id
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

Registry credentials are resolved by matching the image host against the `registries.host` of the run's organization (`Registries.get_registry_for_image/2`). Credentials are therefore configured once per registry, not per test definition. Images whose host has no matching registry are pulled anonymously.

- `host` is unique per organization, with no scheme or path, and stored the way `ImageRef` reports hosts: trimmed, lowercase, `index.docker.io` as `docker.io`. Otherwise a registry could never match.
- `name`, `username`, and `password` are required. The password is never sent back to the browser: on the edit form, an empty password means "keep the current one".
- **Test connection** calls the Docker Engine's `POST /auth` with the form's values (an empty password on the edit form uses the stored one). This authenticates without pulling. It runs asynchronously and shows Docker's message as-is.

See section 36.

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

- `slug` is unique per project (`production`, `staging`); it is what `TestFleet_ENVIRONMENT` contains.
- `max_concurrent_runs` is required, 1..100, default **1**: a new environment is protected by default, and raising the limit is a deliberate choice. Environments belong to a project, so the limit protects *this project's* environment (for example the Customer Portal production system), not every production system. See section 32.

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

- **Key:** `^[A-Za-z_][A-Za-z0-9_]*$`, unique per environment. Keys starting with `TestFleet_` (case-insensitive) are reserved and rejected (section 12).
- **Value:** any string; may be empty for non-secrets. All values are encrypted at rest, not only secrets.
- **Secret** values:
  - must be at least 6 characters, because shorter values cannot be masked reliably (section 21)
  - are never sent to the browser after saving: the list shows `••••••`, the edit form an empty field with "leave empty to keep the current value", also after a failed save
  - cannot be turned back into non-secrets without entering a new value
  - are redacted from `inspect` output

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

last_tick_at
last_tick_outcome
last_run_id

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

- A schedule's test definition and environment belong to the **same project**. Only enabled test definitions can be chosen.
- `cron_expression`: exactly five fields, or an alias such as `@daily`; `@reboot` is rejected, whitespace is normalized, and an expression that never matches a date (`0 0 30 2 *`) is rejected. Minute-level precision.
- `timezone`: an IANA name, validated against the timezone database. The form offers the canonical zones of `zone1970.tab` plus `Etc/UTC`, and preselects `config :testfleet, :default_timezone` (`Europe/Vienna`).
- `next_run_at` is stored in UTC. It is computed by `TestFleet.Schedules.Cron` from local wall-clock time in the schedule's timezone, and recomputed whenever a schedule is created, its cron expression or timezone is edited, or it is re-enabled:
  - a local time that does not exist (spring forward) moves to the first valid instant after the gap
  - a local time that occurs twice (fall back) uses the first occurrence
  - so every local wall-clock time runs at most once. A schedule that runs every few minutes pauses during the repeated hour of a fall-back night. Accepted: it is the price of never running a daily 02:30 schedule twice.
- `last_tick_at`, `last_tick_outcome` (`created`, `skipped_overlap`, `skipped_disabled`), and `last_run_id` (`on_delete: :nilify_all`) record what the last tick did. The tick writes them with a direct update, so `updated_at` keeps meaning "configuration changed". A skip keeps `last_run_id`, so a skipped row can point to the run that blocked it.
- The form previews the next three run times, and offers presets (every day at 06:00, weekdays at 06:00, every hour, every 15 minutes).

`overlap_policy` defines what happens when the schedule fires while one of its own runs is still `queued`, `preparing`, or `running`:

```text
skip   → no new run (default)
queue  → a new run waits for the previous one
allow  → runs may execute in parallel
```

See section 27 for the exact rules.

---

## Encryption at rest

Environment variable values, registry passwords, notification webhook URLs, and signing secrets are encrypted with `cloak_ecto` (`Cloak.Ciphers.AES.GCM`) through `TestFleet.Vault`.

```text
prod   CLOAK_KEY environment variable (base64, 32 bytes), required at boot
dev    fixed key in config/dev.exs
test   fixed key in config/test.exs
```

Losing `CLOAK_KEY` makes these values unreadable; it is backed up with the database (section 43). Key rotation (a second key, a `retired` tag, a re-encryption task) is not built yet; the vault configuration already supports several ciphers.

---

# 7. Runs

Every execution creates an immutable run record.

```text
runs

id

organization_id
test_definition_id
environment_id

trigger
schedule_id
scheduled_for
triggered_by_user_id
api_token_id

status
cancel_requested_at

image
image_digest
command

container_id
last_log_timestamp
last_log_sequence
log_bytes
log_truncated

queued_at
started_at
finished_at

exit_code
oom_killed
error_message

tests_passed
tests_failed
tests_skipped
warnings

pinned
artifacts_expired_at
logs_expired_at

inserted_at
updated_at
```

`trigger` records why the run exists:

```text
manual    → "Run now" in the UI (triggered_by_user_id is set)
schedule  → created by the schedule tick (schedule_id and scheduled_for are set)
api       → created through the API (triggered_by_user_id is the token's user, api_token_id the token)
```

Runs are shown as `#<id>`. Run ids are global, not per organization.

`organization_id` is copied from the project when the run is created. Runs are listed, broadcast, and opened by id without going through their project, so they carry their organization themselves; a run of another organization is "not found".

**Foreign keys.** `test_definition_id` and `environment_id` are `on_delete: :restrict`: run history must not disappear with its configuration. A project, test definition, or environment with runs cannot be deleted; the context returns `{:error, :has_runs}`, and the UI suggests disabling the test definition instead. `schedule_id`, `triggered_by_user_id`, and `api_token_id` are nullable and `on_delete: :nilify_all`.

**What is copied, what is read later.** `image` and `command` are copied from the test definition when the run is created, so the run records what it was asked to execute, even if the definition is edited while the run is queued. Everything else (timeout, resource limits, variables, registry credentials) is read when the run is started. A queued run therefore picks up a changed variable, but never a changed image.

**Times.** `queued_at`, `started_at`, and `finished_at` are `utc_datetime_usec`. `started_at` and `finished_at` are the container's `State.StartedAt` and `State.FinishedAt`, so a run's duration is the suite's own, on one clock. TestFleet's clock is the fallback for `finished_at` when the container cannot tell (it never started, or disappeared).

**Other fields.**

- `image_digest`: the repo digest after the pull (section 37). Null for locally built images without one.
- `container_id`, `last_log_timestamp` (bigint, nanoseconds), and `last_log_sequence` let a restarted TestFleet reattach to a running container and resume the log without gaps or duplicates (section 30).
- `log_bytes` and `log_truncated`: the log limit (section 21).
- `tests_passed`, `tests_failed` (failures and errors), `tests_skipped`: counts from JUnit, `nil` without JUnit, so run lists show them without counting rows.
- `warnings`: collection problems, such as the artifact size limit or an unreadable JUnit file.
- `pinned`, `artifacts_expired_at`, `logs_expired_at`: retention (section 40).
- `cancel_requested_at`: a persisted cancel request (section 25).

**Indexes.** Unique on `(schedule_id, scheduled_for)`, so a schedule never creates two runs for the same slot; on `status` where the status is active; on `(test_definition_id, id)`, `(environment_id, status)`, and `(image, image_digest)` where a digest exists.

**Status transitions.** Every transition is a conditional update (`WHERE status IN (...)`), so a late or repeated event can never reopen a finished run:

```text
queued     → preparing   the dispatcher admits the run
queued     → cancelled   cancel before admission
preparing  → running     container started
preparing  → final       pull/create/start failed, or cancelled while preparing
running    → final       container exited, timed out, or cancelled
```

A final status is set together with `finished_at`, `exit_code`, `oom_killed`, and `error_message` in one update. Every update that makes a run final also inserts its notification evaluation job in the same transaction (section 39).

**`TestFleet.Runs`** is the only writer of runs:

```elixir
create_run(test_definition, environment, opts)   # trigger, user, api_token; manual and API runs
create_scheduled(schedule, scheduled_for)        # called by the tick, inside its transaction
get_run!(id)
list_runs(opts)                                  # newest first; :limit, :project, :test_definition, :statuses
cancel_run(run)                                  # idempotent
build_request(run)                               # the Execution.Request, section 14
append_log(run_id, lines)                        # section 21
finish(run, result)                              # section 23
```

`create_run` reads the test definition again, so a definition disabled after the page loaded is rejected, and rejects an environment of another project.

## Image reproducibility

The run stores the exact image used. Users may configure `e2e:1.17`, or even a mutable tag such as `e2e-latest` (a common pattern: the application's pipeline pushes the tag, and the next run picks it up), but the run records the resolved digest:

```text
image         e2e:1.17
image_digest  sha256:abc123...
```

Historical runs therefore remain traceable even if a tag moves. `image@sha256:...` is the configuration for exact reproducibility.

---

# 8. Run Statuses

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

### queued

The run has been created but execution has not started.

### preparing

TestFleet admitted the run and is preparing it: pulling the image, creating the container.

### running

The container is actively executing.

### passed

The test suite completed successfully.

### failed

The test suite executed but one or more tests failed.

### cancelled

A user or the system cancelled execution.

### timeout

The configured maximum execution duration was exceeded.

### error

TestFleet could not execute the test suite: the registry or image was unavailable, Docker was unreachable or interrupted, the container could not start, was OOM-killed, or disappeared.

The distinction between `failed` (the tests failed: the application team's problem) and `error` (TestFleet or the infrastructure failed) is fundamental. The UI gives every status its own colour and icon, and `failed` and `error` look clearly different.

---

# 9. Run Logs

```text
run_logs

id
run_id

sequence
stream
content
timestamp
```

| Column | Notes |
|--------|-------|
| `run_id` | `on_delete: :delete_all` |
| `sequence` | 1, 2, 3, … per run, assigned by `RunExecution` |
| `stream` | `stdout` or `stderr` |
| `content` | masked, without the trailing newline; NUL bytes replaced with `U+FFFD`, because PostgreSQL `text` cannot hold them |
| `timestamp` | Docker's own log timestamp in nanoseconds (nullable), not TestFleet's receive time |

- One row represents one line. Docker log frames are not line-aligned; `RunExecution` splits them (section 21).
- A unique index on `(run_id, sequence)` serves loading the log and its tail in order, and makes a repeated insert after a reattach harmless (`on_conflict: :nothing`).
- No `inserted_at`/`updated_at`: rows never change, and `timestamp` holds the time that matters. This keeps the largest table narrow.

The database contains the complete historical log, up to the per-run log limit (section 21). PubSub only delivers new output to connected clients.

Logs are an append-only event stream. `sequence` makes the order deterministic. `run_logs` is a good candidate for monthly partitioning once it grows, so retention becomes dropping a partition.

---

# 10. Test Results

Test suites can optionally produce JUnit XML. TestFleet parses it into:

```text
test_results

id
run_id
test_definition_id

suite
classname
name

status
duration_ms

failure_message
failure_details

file
inserted_at
```

- `run_id` and `test_definition_id` are `on_delete: :delete_all`. `test_definition_id` is copied from the run for the identity below.
- `suite` is the innermost enclosing `<testsuite name>`; `classname` may be empty.
- `status`: `passed`, `failed`, `error`, `skipped`.
- `duration_ms` from `time` (seconds, possibly fractional).
- `failure_message` is the `message` attribute of `<failure>`/`<error>`; `failure_details` the element's text (stack trace), cut at 64 KiB.
- `file`: the JUnit file it came from, such as `junit/shard-2.xml`.
- No `updated_at`: rows never change.

A test's identity across runs is `(test_definition_id, suite, classname, name)`. This combination is indexed so per-test history and flakiness (a test alternating between passed and failed without an image change) can be queried later. An index on `(run_id, status)` lists failed tests first.

## Files

TestFleet parses every `*.xml` file directly under `/TestFleet/artifacts/junit/`, plus `/TestFleet/artifacts/junit.xml` if present. Sharded suites therefore produce one file per shard. The files stay artifacts too.

## Parsing

`TestFleet.Results.JUnit.parse/1` is a pure function.

- Accepts `<testsuites>` at the root, a single `<testsuite>`, and nested suites (Jest).
- `<testcase>` with `<failure>` is `failed`, with `<error>` `error`, with `<skipped>` `skipped`, otherwise `passed`. `<system-out>`, `<system-err>`, and `<properties>` are ignored.
- **Safety:** parsed with OTP's `:xmerl_sax_parser` without external entities. A document with a `<!DOCTYPE` is rejected, which rules out entity expansion attacks. A file over 50 MiB is not parsed.
- A file that cannot be parsed adds a warning to the run ("junit/shard-2.xml could not be parsed: …") and is ignored. If no file could be parsed, the run counts as having no JUnit.

JUnit is parsed in `RunExecution`, where the files are extracted, because the final status depends on it (section 23).

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
```

- `name`: the path relative to the artifacts directory, such as `screenshots/login.png`. Unique per run.
- `content_type` from the extension (`MIME.from_path/1`).
- `storage_backend` is `local`; `storage_key` is `<run_id>/<name>`.
- No `updated_at`: artifacts never change.

Artifacts may include JUnit files, screenshots, videos, Playwright traces, HTML reports, logs, and coverage reports.

## Storage

`config :testfleet, TestFleet.Artifacts, root: ...` (`ARTIFACTS_DIR`; `/app/artifacts` in the image, `tmp/artifacts` in development, `tmp/test_artifacts` in tests). A run's files go to `<root>/<run_id>/`.

`TestFleet.Artifacts.Storage` is the only module that turns a storage key into a file path. It has one backend, `Local`. Object storage would add a backend and an upload step after collection; the execution model stays the same.

The database stores metadata only; binary files are never stored in PostgreSQL.

## Collection

After the container stops, `RunExecution` downloads `/TestFleet/artifacts` as a tar stream (the Engine API's archive endpoint) into `<run_id>.tar` next to the run's directory, and extracts it. Docker puts the directory's contents under a top-level `artifacts/` entry, which is stripped. A 404 (no directory) means no artifacts, and is not an error. Artifacts are collected after a timeout or a cancel too: partial screenshots and traces are often the most useful debugging material.

**Size limit.** `config :testfleet, TestFleet.Artifacts, max_bytes: 500 * 1024 * 1024` (`ARTIFACT_LIMIT_MB`).

- The archive is downloaded with a byte cap: the download stops as soon as it passes the limit, so a suite that writes 20 GB of video cannot fill TestFleet's disk first. The limit is measured on the tar stream, which adds about 512 bytes per file.
- Over the limit, the partial download is deleted. TestFleet then downloads only `junit.xml` and `junit/`, each with the same cap, keeps those, and records the warning "Artifacts exceeded 500 MiB; only the JUnit files were kept".

**Safe extraction.** A tar stream from a container is untrusted input. TestFleet reads the tar's table first and extracts only regular files and directories: symbolic and hard links, devices, FIFOs, and names that are absolute or contain `..` are skipped, and counted in one warning ("3 entries were skipped: links or unsafe paths").

## Persisting

`Runs.finish/2` writes the final status, the test counts, the warnings, the `artifacts` rows, and the `test_results` rows (in chunks of 1,000) in **one transaction**, then broadcasts `{:run_finished, run}`. A run is never visible as finished without its results. The inserts use `on_conflict: :nothing`, and the guarded transition means a second finish (after a reattach) changes nothing. If an insert fails, the transaction rolls back, the run stays active, and the reconciler finishes it (section 31).

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

The `TestFleet_` prefix is reserved and cannot be set by users. `TestFleet_ENVIRONMENT` is the environment's slug.

The image must not require interactive input, mounted files, or build-time secrets.

## Execution

- The image starts its suite through its `ENTRYPOINT`/`CMD`, or through the configured `command`.
- The suite must finish within the configured timeout.
- On `SIGTERM` the suite should exit promptly; TestFleet sends `SIGKILL` after a grace period (section 24).

## Output

- **Exit code:** `0` means all tests passed; any other code means failure. See section 23 for how the exit code combines with other signals.
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

TestFleet copies the directory out of the stopped container, with a size limit (section 11).

---

# 13. Execution Architecture

The execution subsystem is intentionally separated from Oban.

```text
Run created (status = queued)
  │
  ▼
Execution.Dispatcher        ← admission control (section 32)
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

Runs are not started through an Oban job. An Oban job that only calls `Execution.start/2` returns immediately and frees its queue slot while the container keeps running, so Oban's queue limits would not limit containers at all. Blocking the job until the container exits would fix the limit, but would tie the job's lifetime to the container and let Oban's orphan rescue start the same run twice after a crash.

The supervision tree has:

```elixir
{Registry, keys: :unique, name: TestFleet.Execution.Registry},
{Task.Supervisor, name: TestFleet.Execution.TaskSupervisor},
TestFleet.Execution.PullCoordinator,
{DynamicSupervisor, name: TestFleet.Execution.Supervisor, strategy: :one_for_one},
TestFleet.Execution.Dispatcher,      # not in tests (start: false); tests start their own
TestFleet.Execution.Reconciler,
TestFleet.Notifications.Watchdog     # outside Oban, so a stuck cron shows (section 39)
```

The coordinator and the task supervisor start before the run processes' supervisor, so they stop after them.

**Principle:** PostgreSQL and Docker are the truth; processes are disposable. Whatever a process fails to finish, the reconciler finishes by comparing the two (section 30).

---

# 14. Execution Engine

`TestFleet.Execution` is the interface the rest of TestFleet uses:

```elixir
Execution.start(request, opts)        # starts a RunExecution under Execution.Supervisor
Execution.attach(run_id, opts)        # adopts an existing container (section 30)
Execution.cancel(run_id)              # :ok, idempotent
Execution.executing?(run_id)          # is a RunExecution registered?
Execution.list_containers()           # containers labelled TestFleet=true, with run id, state, instance
Execution.docker_status()             # the dispatcher's view of Docker (section 31)
Execution.run(attrs)                  # build a request, start, and wait; for mix testfleet.try and tests
```

The dispatcher reaches it through an engine module from configuration (`TestFleet.Execution` by default), so its tests use a fake engine. Other backends (ECS, Kubernetes) would implement the same interface (section 45).

## Request

```elixir
defmodule TestFleet.Execution.Request do
  defstruct [
    :run_id,
    :image,
    :project_id,
    :instance_id,
    :environment_name,
    :registry_auth,
    :artifact_path,
    :max_artifact_bytes,
    :cpu_limit,
    :memory_limit,
    command: [],
    environment: %{},
    timeout_seconds: 1800,
    stop_grace_seconds: 30,
    shm_size: 2_147_483_648,
    pull_policy: :auto,
    pull_timeout_ms: 600_000,
    secret_keys: []
  ]
end
```

`Runs.build_request/1` fills it:

| Field | Source |
|-------|--------|
| `run_id` | `runs.id` |
| `project_id`, `environment_name` | the test definition's project; the environment's slug |
| `instance_id` | `TestFleet.Instance.id/0` (section 30) |
| `image`, `command` | the run (copied at creation) |
| `environment` | the environment's variables, decrypted |
| `secret_keys` | the keys of its secret variables, for masking (section 21) |
| `registry_auth` | `Registries.get_registry_for_image/1`, or `nil` for an anonymous pull |
| `timeout_seconds`, `cpu_limit`, `memory_limit`, `shm_size` | the test definition |
| `artifact_path`, `max_artifact_bytes` | `<artifacts root>/<run_id>`, the artifact limit (section 11) |
| `pull_policy`, `pull_timeout_ms`, `stop_grace_seconds` | `:auto`, configuration (section 37), 30 |

The request holds decrypted secrets. It is never logged, and `Request` redacts `environment` and `registry_auth` from `inspect`.

## Events and the handler

`RunExecution` reports what happens through a **handler**: a module implementing `TestFleet.Execution.Handler` (`handle_event(run_id, event)`), called inside the `RunExecution` process. `TestFleet.Runs.Recorder` is the handler that writes to the database; a pid subscriber handler serves `Execution.run/1` and tests.

| Event | Recorded by `Runs.Recorder` |
|-------|-----------------------------|
| `{:status, :preparing}` | nothing (the dispatcher already set it) |
| `{:image_digest, digest}` | `image_digest` |
| `{:container_created, id}` | `container_id` |
| `{:running, started_at}` | `status = running`, `started_at` (the container's `StartedAt`) |
| `{:output, lines}` | `Runs.append_log/2` (section 21) |
| `{:finished, %Result{}}` | `Runs.finish/2` (section 11) |

The writes happen in the run's own process, so runs are recorded in parallel, and the dispatcher never waits for a database write. If a write fails, the handler raises and `RunExecution` crashes; the container keeps running and the reconciler reattaches (section 31).

`Result` carries the status, exit code, OOM flag, error message, image digest, container id, start and finish times, artifacts, test results, and warnings.

---

# 15. Docker Execution Lifecycle

```text
ensure network TestFleet-runs
      ↓
resolve image, pick credentials by host
      ↓
pull (per pull policy, through the PullCoordinator, within the pull timeout)
      ↓
inspect image → image_digest
      ↓
create container TestFleet-run-<id>
      ↓
start
      ↓
inspect → started_at, arm deadline
      ↓
open logs stream + wait stream
      ⋮  log chunks, wait result, deadline, cancel, broken streams
wait returned
      ↓
drain remaining log chunks, flush the last batch
      ↓
inspect → exit code, OOMKilled, finished_at
      ↓
collect artifacts, parse JUnit
      ↓
decide status, report {:finished, result}
      ↓
remove container
```

The individual Docker operations are separate API calls, not one `docker run`.

Containers are **not** created with `AutoRemove`. The exit code, the `OOMKilled` flag, and the artifacts must be read from the stopped container before TestFleet removes it.

`{:finished, result}` is reported **before** the container is removed. If TestFleet dies between the two, the run is already final, and the reconciler removes the leftover container (section 30). In the other order, the run would stay `running` without a container.

---

# 16. Container Naming and Labels

Containers have deterministic names:

```text
TestFleet-run-1842
```

and labels:

```text
TestFleet=true
TestFleet.run_id=1842
TestFleet.project_id=12
TestFleet.organization_id=3
TestFleet.instance=<uuid>                  section 30
TestFleet.timeout_seconds=1800             section 24
TestFleet.stop_grace_seconds=30
TestFleet.secret_keys=API_TOKEN,PASSWORD   section 21
```

Labels are essential for cleanup, recovery, reconciliation, debugging, and identifying containers belonging to TestFleet. Everything a reattaching process needs is on the container, because it has no request: the deadline, the grace period, and which variables to mask.

---

# 17. Resource Limits

Each test definition can define a CPU limit, a memory limit, the shared memory size, and its timeout (section 6). They become `NanoCpus`, `Memory`, `ShmSize`, and the deadline.

`MemorySwap` is set equal to `Memory`. Otherwise Docker allows as much swap again, and a suite over its memory limit swaps instead of being OOM-killed.

This prevents a single badly behaved test suite from consuming unlimited resources.

---

# 18. Docker Command Abstraction

## Docker Engine API, not the Docker CLI

TestFleet talks to the **Docker Engine HTTP API** with Req, rather than shelling out to the `docker` CLI. The endpoint comes from `DOCKER_HOST`: the socket proxy in the deployed setup (section 43), or a socket in local development.

Reasons:

- **Per-request registry authentication.** A pull passes credentials in the `X-Registry-Auth` header. The CLI's `docker login` writes one global config file, which causes races when concurrent runs pull from different registries.
- **Structured errors.** The API returns status codes and JSON error bodies. TestFleet needs these to tell `error` apart from `failed` reliably; parsing CLI stderr is brittle.
- **No CLI dependency.** The TestFleet image does not ship the `docker` binary.
- **Streaming.** Logs, pull progress, and `wait` are HTTP streams that map naturally onto an Elixir process.

## `Docker.Client`

- `DOCKER_HOST` `tcp://h:p` becomes `base_url: "http://h:p/v1.44"`; `unix://path` becomes `unix_socket: path`. Windows named pipes are not supported by Req, so development on Windows goes through the socket proxy from the development `compose.yaml`.
- All requests use the pinned API version prefix `/v1.44` (Docker Engine 25+). `ping/0` checks `GET /version` and fails with a clear error when the daemon is older.
- Req's automatic retries are off: Docker operations are not blindly retryable.
- Errors are normalized to `{:error, %{status: integer | nil, message: String.t(), reason: term}}`; Docker's `{"message": "..."}` is surfaced as-is. A transport error (proxy down, connection refused) has `status: nil`.

## `Docker.Command`

One function per Engine API call. No other module builds Docker URLs.

| Function | Endpoint | Notes |
|----------|----------|-------|
| `ping/0` | `GET /_ping`, `GET /version` | version check |
| `check_auth/2` | `POST /auth` | registry "Test connection" |
| `ensure_network/1` | `GET /networks/{name}`, `POST /networks/create` | create if 404 |
| `pull/2` | `POST /images/create?fromImage=…&tag=…` | `X-Registry-Auth`; errors arrive inside the stream (below) |
| `inspect_image/1` | `GET /images/{name}/json` | `RepoDigests` for the digest |
| `list_images/0` | `GET /images/json` | image cleanup |
| `remove_image/1` | `DELETE /images/{name}@{digest}` | without `force`; 404 is `:ok` |
| `create/2` | `POST /containers/create?name=…` | 409: the name exists |
| `start/1` | `POST /containers/{id}/start` | 304 (already started) is `:ok` |
| `logs/2` | `GET /containers/{id}/logs?follow=1&stdout=1&stderr=1&timestamps=1&since=…` | streaming |
| `wait/1` | `POST /containers/{id}/wait?condition=not-running` | streaming |
| `inspect/1` | `GET /containers/{id}/json` | `ExitCode`, `OOMKilled`, `StartedAt`, `FinishedAt`, `Config.Env` |
| `stop/2` | `POST /containers/{id}/stop?t=…` | 304 (already stopped) is `:ok` |
| `kill/1` | `POST /containers/{id}/kill` | 409 (not running) is `:ok` |
| `archive/2` | `GET /containers/{id}/archive?path=…` | tar stream to a file, with a byte cap; 404 means no artifacts |
| `remove/1` | `DELETE /containers/{id}?force=true&v=true` | 404 is `:ok` |
| `list/1` | `GET /containers/json?all=true&filters=…` | by label `TestFleet=true` |

All "already in that state" responses are treated as success. This is what makes stop, kill, cancel, and cleanup idempotent.

Streaming calls (`logs`, `wait`) use `into: :self` with `receive_timeout: :infinity`, so the chunks arrive as messages in the `RunExecution` process (`Req.parse_message/2`). No extra processes wait on Docker. Each running run holds two long-lived connections; the Finch pool is sized for the global concurrency limit.

**Pull errors.** `POST /images/create` answers `200` and then reports failures **inside** the JSON progress stream as `{"error": "...", "errorDetail": {...}}` ("unauthorized", "manifest unknown"). `pull/2` reads the stream to the end and returns `{:error, ...}` when any line contains `error`. A `200` alone does not mean the pull worked.

## `Docker.RegistryAuth`

Encodes `%{username, password, serveraddress}` as JSON, then **URL-safe base64**, into `X-Registry-Auth`. Anonymous pulls send no header.

## `Docker.ImageRef`

Parses an image reference into host, repository, tag, and digest, with Docker's rules:

```text
e2e:1.17                                  → host docker.io, repo library/e2e, tag 1.17
registry.company.com/customer-a/e2e:1.17  → host registry.company.com
localhost:5055/fixture-suite@sha256:…     → host localhost:5055, digest sha256:…
```

The first path segment is a host only if it contains `.` or `:`, or is `localhost`. The host decides the registry credentials (section 36), the digest the pull policy (section 37). `ImageRef.put_tag/2` (used by the API) keeps the reference as written (`e2e:1.4` becomes `e2e:1.5`, not `library/e2e:1.5`), keeps a registry port, and drops a digest. `ImageRef.name/1` is the form Docker lists in `RepoDigests` (`alpine` for Docker Hub's `library/alpine`).

---

# 19. Container Creation

Conceptually:

```bash
docker create \
  --name TestFleet-run-1842 \
  --label TestFleet=true \
  --label TestFleet.run_id=1842 \
  --label TestFleet.project_id=12 \
  --memory=4g --memory-swap=4g \
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

The implementation uses the equivalent Engine API call: `Tty: false` (so stdout and stderr stay separable), `AutoRemove: false`, `Cmd` only when `command` is non-empty, and the labels of section 16.

## Network

Test containers run on a dedicated Docker network, `TestFleet-runs`, which TestFleet creates if it is missing.

They must **never** join the Compose network that TestFleet, PostgreSQL, and the socket proxy use. Otherwise any test suite could reach TestFleet's database or the Docker API.

## Hardening

Every test container gets:

- `no-new-privileges`
- all Linux capabilities dropped
- never `Privileged`
- no host mounts (`Binds`), and in particular never the Docker socket

If a suite genuinely needs a capability, that becomes an explicit, visible setting on the test definition, not a default.

## Secrets

Secrets are passed as container environment variables and never written into TestFleet's application logs. Environment variables are visible to anyone who can run `docker inspect` on the host; for the trusted internal deployment this is accepted (section 34). Secrets printed by the suite itself are masked before logs are stored (section 21).

## Idempotent start

The deterministic name means a second attempt to create the same container fails with `409` instead of starting the suite twice. That run finishes `error` and never touches the container: it belongs to another execution, and in particular must not be removed.

---

# 20. Container Start

After creation, the container is started. It then runs independently of the Phoenix process.

If TestFleet crashes or restarts while a test is running, the container continues, and the reconciler adopts it again (section 30). This is one of the reasons execution is designed around independently identifiable containers.

```text
Run #1842 → container starts → TestFleet stops → container keeps running
          → TestFleet starts → reconciler finds the container → run continues
```

---

# 21. Live Log Streaming

```text
Docker log stream (multiplexed frames, with timestamps)
  ↓
LogDecoder: frames → {stream, timestamp, bytes}
  ↓
LineBuffer: lines, per stream
  ↓
Masker: secret values → [MASKED]
  ↓
sequence numbers, batch (100 ms / 500 lines / 1 MiB)
  ↓
{:output, lines} → Runs.append_log → run_logs, then {:run_output, lines} on run:<id>
```

## Decoding

Containers run without a TTY, so the log stream is multiplexed. Each frame has an 8-byte header (byte 0: 1 = stdout, 2 = stderr; bytes 4–7: payload length, big-endian) and the payload. HTTP chunks do not align with frames; `Docker.LogDecoder` keeps the unconsumed bytes and returns complete frames only.

With `timestamps=1`, Docker prefixes every message with an RFC 3339 nanosecond timestamp. It is kept as **integer nanoseconds**: `DateTime` only keeps microseconds, and resuming without duplicates needs the full precision.

## Lines

`Execution.LineBuffer` keeps one partial-line buffer **per stream** and emits a line only at `\n`. Docker splits long lines into 16 KB messages, and a message may lack a trailing newline.

- A line's timestamp is that of its first fragment.
- A trailing `\r` is stripped; invalid UTF-8 becomes `U+FFFD`.
- A partial line that grows past 1 MB without a newline is emitted as is. Otherwise a suite that prints progress with `\r` only would grow the buffer for its whole run.
- When the stream ends, the remaining partial lines are flushed.

## Secret masking

`TestFleet.Execution.Masker` replaces every occurrence of a secret value with `[MASKED]`, in `RunExecution`, on each complete line, before numbering and batching. No event, handler, or subscriber ever sees an unmasked line.

- The values of the request's `secret_keys`. A multi-line secret (a PEM key) is masked line by line; each of its lines of at least 6 characters is a pattern.
- One compiled pattern per run. When several secrets match at the same position, the longest wins, so a secret that contains another is masked completely.
- **After a reattach**, the process has no request. It reads the keys from the container's `TestFleet.secret_keys` label and their values from the inspected container's `Config.Env`, so masking never depends on variables that changed since the run started.

Test suites regularly echo configuration or print request headers; without masking, secrets end up in the database and the browser. Very short secrets cannot be masked reliably and are rejected when saved (section 6).

**Known limits:** a secret split across two lines (or by the 1 MB split), interrupted by ANSI escape codes, or encoded (base64, URL encoding) is not masked. Non-secret variables are never masked.

## Batching

Chatty suites produce thousands of lines per second. Writing and broadcasting line by line would overload PostgreSQL and the LiveView. `RunExecution` emits `{:output, lines}` when the first of these happens:

- 100 ms have passed since the first line of the batch arrived (a timer per batch, not a periodic tick)
- 500 lines are pending
- 1 MiB of content is pending (lines can be up to 1 MB long)

The pending batch is flushed before `{:finished, result}`, so all stored lines are in PostgreSQL before the run is final. The handler is called once per batch, and the Docker stream is not read while a batch is written: a slow database slows down reading the log, not the suite; Docker keeps the output.

## Persisting

`Runs.append_log(run_id, lines)`, in one transaction:

1. Update the run: `last_log_sequence` (the batch's last line), `last_log_timestamp` (its **newest** line: stdout and stderr interleave, so the last line is not always the newest, and resuming skips every line not newer than this), and `log_bytes`.
2. `insert_all` the lines that fit under the log limit (`on_conflict: :nothing`).
3. If a line does not fit, store none of the later lines, and set `log_truncated = true`.

Then broadcast `{:run_output, lines}` on `run:<id>` with **all** lines of the batch, stored or not. Once the limit is reached, a batch only updates the run and is broadcast; `{:run_updated, run}` is broadcast once, when a batch reaches the limit.

## Log limit

`config :testfleet, TestFleet.Runs, max_log_bytes: 50 * 1024 * 1024` (`RUN_LOG_LIMIT_MB`), counted on `content`.

Beyond it, TestFleet stops persisting lines and keeps streaming to connected clients. The truncation marker is the flag `runs.log_truncated`, not a row, so `run_logs` holds only container output; the run page and the download render it as a final line.

Very large logs could move to object storage later, with metadata kept in PostgreSQL.

---

# 22. PubSub

| Topic | Events | Subscribers |
|-------|--------|-------------|
| `run:<id>` | `{:run_created, run}`, `{:run_updated, run}`, `{:run_finished, run}`, `{:run_output, lines}` | the run page, after a scoped lookup of the run |
| `runs:<organization_id>` | the same, **without** `{:run_output, _}` | runs list, dashboard, project and test definition pages |
| `runs` | the same, for all organizations | the dispatcher only; never a LiveView |
| `system` | `{:docker_status, %{reachable, since, message}}` | dashboard |
| `notifications:<organization_id>` | deliveries, with their channel redacted | delivery log, run page |

A page subscribes only to its organization's topics, so one organization's runs and deliveries never reach another's browser.

```elixir
{:run_updated, run}      # status or recorded facts changed: running, image digest, cancel requested, expired
{:run_output, [
  %{sequence: 42, stream: :stdout, content: "Running checkout test...", timestamp: 1_790_000_000_000_000_000},
  %{sequence: 43, stream: :stdout, content: "✓ Checkout", timestamp: 1_790_000_000_100_000_000}
]}
{:run_finished, run}     # reached a final status; its results and artifacts are stored
```

Run events carry the whole run with its test definition, project, and environment preloaded, so subscribers need no extra query. The run's user and token are preloaded with only `id` and `email`/`name`, because runs are broadcast.

There is no per-test event: JUnit exists only after the suite finished, so test results arrive with `{:run_finished, run}`, whose counts tell the page to load them.

A broadcast that announces a database change is sent after the commit; otherwise a subscriber could read the database before the change is visible.

---

# 23. Waiting for Completion and the Final Status

`RunExecution` waits for the container to exit (the `wait` stream) and drains the remaining logs. On a busy host, the log stream can lag seconds behind a suite that wrote a lot just before it exited. Draining therefore ends when the stream ends, or after it was silent for 5 s; the time since the exit does not count. A stream cut off by that timeout is logged as a warning.

Then it inspects the container for its exit code, `OOMKilled`, and `FinishedAt`, collects artifacts, and parses JUnit.

Exit code alone does not determine the final status. Infrastructure failures must remain distinguishable from test failures.

## Final Status Decision Table

`TestFleet.Execution.Status.decide/1` is a pure function. The first matching rule wins.

| # | Condition | Status |
|---|-----------|--------|
| 1 | User or system cancelled the run | `cancelled` |
| 2 | Timeout expired | `timeout` |
| 3 | Failure before the container started (registry, pull, pull timeout, create, start) | `error` |
| 4 | Container state `OOMKilled = true` | `error` (memory limit exceeded) |
| 5 | Container disappeared while running | `error` |
| 5a | TestFleet lost Docker while the suite ran, the container exited meanwhile, and the exit code is non-zero | `error` (Docker was interrupted) |
| 6 | Exit code `0` and JUnit reports failures or errors | `failed` |
| 7 | Exit code `0` | `passed` |
| 8 | Exit code non-zero and JUnit reports at least one failure | `failed` |
| 9 | Exit code non-zero and JUnit present, but no failures reported | `error` (suite crashed outside of tests) |
| 10 | Exit code non-zero and no JUnit | `failed` |

Notes:

- Rule 6 protects against suites that swallow their own exit code.
- Rule 9 catches crashes in setup/teardown, reporters, or the runner itself, which are not test failures. Its message: "The suite exited with code N, but its JUnit report has no failures".
- Rule 10 is deliberately `failed`, not `error`: without structured results TestFleet cannot tell the difference, and a false "infrastructure error" is worse than a false "test failure".
- Exit code `137` without `OOMKilled` (killed by TestFleet during timeout or cancellation) is covered by rules 1 and 2.
- Rule 5a catches a Docker daemon restart, which stops every suite with `143` or `137`; without it, rule 10 would call that `failed`. See section 31.
- Rules 1–5 win over JUnit, but a cancelled, timed-out, or OOM-killed run still stores its results and artifacts; partial results are often the most useful.

---

# 24. Timeout Handling

Every execution has a maximum duration (`timeout_seconds`). `RunExecution` owns it.

The deadline is always derived from the container's start:

```text
deadline = started_at + timeout_seconds
```

never from a fresh in-memory timer. A process that reattaches (section 30) or follows the container again after a broken stream (section 31) enforces the original deadline; if it has already passed, the container is stopped immediately. Time TestFleet spent down counts against the run's timeout.

When the deadline fires:

```text
running
   ↓
stop (SIGTERM, grace period, default 30 s; Docker sends SIGKILL after it)
   ↓
kill, as a safety net, if the container still runs 5 s later
   ↓
collect artifacts, finalize as timeout, remove
```

The `stop` call blocks for up to the grace period, so it runs in a task and the process stays responsive.

The image pull is not part of the run timeout. Pulls have their own timeout (section 37).

---

# 25. Cancellation

Users cancel from the run page or the API. Cancellation is idempotent: calling it repeatedly, or after the run finished, never corrupts run state.

The request is **persisted**, so a cancel works even when no process owns the run (in the moment between admission and the process start, or while a process is being replaced):

`Runs.cancel_run/1`:

- `queued` → `cancelled` directly (conditional update).
- `preparing` / `running` → set `cancel_requested_at` (if not set), broadcast `run_updated`, then `Execution.cancel/1`. If no process exists, the reconciler finishes the job within one interval (section 30).
- final → nothing.

`RunExecution` stops the container like a timeout (SIGTERM, then SIGKILL), collects artifacts, and finishes `cancelled`.

- During `preparing`, the pull runs in a task, so a cancel takes effect immediately: the task is shut down, and the run finishes `cancelled` without a container.
- A cancel after the deadline started stopping the container changes nothing: the run stays `timeout`.
- `Execution.attach/2` takes `cancel: true`: the adopting process begins the stop at once. On a container that already exited, the suite's own outcome is kept.
- The run page's "Cancelling…" comes from `cancel_requested_at`, so it survives a reload and shows in every open tab.

---

# 26. Per-Run Process

Each active execution has its own `RunExecution` GenServer under `Execution.Supervisor`, registered as `{:via, Registry, {TestFleet.Execution.Registry, run_id}}`.

It owns:

- the container ID
- the pull (through the `PullCoordinator`) and its timeout
- the deadline (from `started_at`, section 24)
- log streaming, masking, and batching
- cancellation
- completion, artifact collection, and JUnit parsing
- the final status
- removing the container

`RunExecution` processes are started with `restart: :temporary`. If one crashes, the supervisor does not restart it blindly; the reconciler inspects the container and reattaches or finalizes the run. This keeps one recovery path instead of two.

---

# 27. Background Jobs and Scheduling

Oban is used for time-based and fire-and-forget work. It does **not** start or own running containers (section 13).

| Worker | Queue | Schedule | `max_attempts` |
|--------|-------|----------|----------------|
| `Schedules.TickWorker` | `schedules` | every minute | 1 |
| `Artifacts.CleanupWorker` | `cleanup` | hourly (`0 * * * *`) | 1 |
| `Notifications.EvaluateWorker` | `notifications` | per final run | 3 |
| `Notifications.DeliveryWorker` | `notifications` | per delivery | 5 |

- Workers that create runs use `max_attempts: 1`: Oban's default of 20 attempts contradicts the retry policy (section 33). A failed tick is not retried; the next minute's tick picks up everything still due.
- **The reconciler owns crash recovery of runs, not Oban.** Oban's Lifeline plugin may rescue TestFleet's own jobs, but never re-executes a run.
- Cron runs only on the leader node.
- Tests run Oban with `testing: :manual`, so no cron fires; tests call the logic (`Schedules.tick/1`, `Retention.run/1`) directly.

## The schedule tick

One static Oban cron entry drives all user-defined schedules:

```elixir
config :testfleet, Oban,
  cron: [crontab: [{"* * * * *", TestFleet.Schedules.TickWorker}, ...]]
```

The tick does not ask "does this cron expression match the current minute?". That approach silently loses runs whenever a tick is late or skipped. Instead every schedule stores its `next_run_at`, and the tick picks up everything that is due. Scheduling stays on Oban OSS; Oban Pro's `DynamicCron` is not required.

`TickWorker` calls `Schedules.tick(DateTime.utc_now())`; all logic is in `tick/1`, which tests call with a fixed `now`:

1. Load the ids of the due schedules: `enabled` and `next_run_at <= now`, oldest first.
2. For each schedule, **in its own transaction**:
   1. Lock it with `FOR UPDATE SKIP LOCKED` and check again that it is enabled and due; skip it if it is locked or no longer due (another tick has it).
   2. Apply the overlap policy and create the run, or skip (`Runs.create_scheduled/2`).
   3. Advance `next_run_at` to the first occurrence **after `now`**, and record the outcome.
3. After each commit, broadcast `{:run_created, run}`; the dispatcher wakes up on it.

Per-schedule transactions mean one broken schedule cannot roll back or block the others, and a lock is held only for a moment. After a completed tick, `TickWorker` pings the heartbeat URL (section 39).

Rules:

- **`scheduled_for`** is the slot the run was due for (the old `next_run_at`), not the time of the tick; `queued_at` is the time of the tick.
- **Missed slots are coalesced.** A schedule that missed slots creates one run for its oldest missed slot, then moves past `now`; the number of missed slots is logged. After three hours of downtime a twice-daily schedule creates one run, not a burst.
- **Never twice.** The row lock covers concurrent ticks, and the unique index on `runs(schedule_id, scheduled_for)` covers everything else. The insert uses `on_conflict: :nothing`; a conflict counts as created and still advances the schedule.
- **Broken schedules.** A cron expression or timezone that no longer parses, or never matches again (data changed by hand, a zone removed), disables the schedule and logs an error; leaving it enabled would fail every minute.
- **Timing.** A schedule for 06:00 creates its run within a few seconds after 06:00. A late or skipped tick only delays runs; it never loses them.

## Overlap policy

A schedule's *own* unfinished runs are its runs (by `schedule_id`) in `queued`, `preparing`, or `running`. Manual runs of the same test definition and environment do not count: they are someone's deliberate choice.

| Policy | Unfinished own run | Result |
|--------|--------------------|--------|
| `skip` (default) | yes | No run; outcome `skipped_overlap`, logged |
| `queue` | a `queued` one | No run; outcome `skipped_overlap`: **at most one run waits** |
| `queue` | only `preparing` / `running` | A queued run, which waits for the previous one (below) |
| `allow` | any | A queued run; only the concurrency limits apply |
| any | none | A queued run |
| any, test definition disabled | – | No run; outcome `skipped_disabled`; the schedule still advances and resumes when the test definition is enabled again |

**`queue` keeps at most one waiting run.** Without the cap, a suite that hangs for three hours under a 15-minute schedule would leave twelve runs waiting, all testing the same thing late.

**`queue` waits for the previous run.** With an environment limit above 1, the dispatcher would otherwise start both in parallel, and `queue` would behave like `allow`. The dispatcher therefore skips a queued run whose schedule has `overlap_policy = queue` while another run of that schedule is active (section 32). The policy is read at dispatch time.

The decision and the insert happen inside the schedule's transaction, so two ticks cannot both see "no unfinished run".

## Cleanup worker

`Artifacts.CleanupWorker` runs these independent steps; a failure in one is logged and does not stop the others:

1. Retention of artifacts and logs (section 40)
2. Unused images (section 37)
3. Orphaned artifact directories (section 29)
4. Notification deliveries older than 90 days (section 39)

---

# 28. Manual, Scheduled, and API Runs

Manual, scheduled, and API runs converge on exactly the same execution pipeline:

```text
Run now                  ─┐
Schedules.TickWorker     ─┼→ create Run (queued) → Execution.Dispatcher → RunExecution
POST /api/v1/…/runs      ─┘
```

The only difference between them is the run's `trigger` (and who started it). There are no separate execution implementations.

---

# 29. Cleanup

Cleanup must happen regardless of how execution terminates, and must be idempotent.

- The normal lifecycle removes the container after reporting the final status, in every outcome.
- `RunExecution` does **not** remove its container when the process itself crashes (no `terminate/2` cleanup). The suite may still be running and can be reattached; removing it would turn a recoverable situation into a lost run.
- `try/after` and `terminate/2` are best effort only: they do not run when the BEAM is killed or the TestFleet container is stopped hard. **The reconciler is the actual guarantee** that every container is eventually removed (section 30).

**Orphaned artifact directories** (`Artifacts.Orphans`, a cleanup step): directories under the artifacts root whose name is not the id of a run in this database, and `<run_id>.tar` / `<run_id>.extract` leftovers of an interrupted collection, are deleted.

- Only names that are entirely digits (at most 18, a bigint) are considered; anything else in the root is left alone.
- A directory of an active run is never touched, and leftovers are kept for every run that is not final.
- The artifacts root belongs to one instance (dev and test use different roots), so no instance check is needed.

---

# 30. Recovery and Reconciliation

TestFleet must not assume Phoenix stays alive for the entire execution. Containers exist independently, so TestFleet compares PostgreSQL with Docker and repairs the difference.

## Instance identity

On a development machine, the dev and test databases share one Docker host, and a server may run a staging and a production TestFleet against one host. A container whose run id is missing from *this* database may be another instance's live run.

- A table `instance` holds one row: `id` (UUID, inserted by its migration with `gen_random_uuid()`), `inserted_at`. Every database gets its own id without configuration. `TestFleet.Instance.id/0` caches it in `:persistent_term`.
- Containers get the label `TestFleet.instance=<id>`; the id arrives in the `Request`, so `Execution` stays free of the database.
- The reconciler only removes orphans with its own instance id. Containers without the label (started by `Execution.start/2` without an instance, as the Docker tests and the try task do) are matched to runs by `TestFleet.run_id`, but never removed as orphans.
- The test database starts run ids at 10^9 (`test/test_helper.exs`), so test containers cannot collide with dev containers of the same name.

## The reconciler

`TestFleet.Execution.Reconciler` is a pure planner (`plan/2`) plus an executor, so the rules are tested without Docker.

- **At startup**, the dispatcher runs a pass in `handle_continue` before its first dispatch. No `RunExecution` can exist yet, so no grace periods apply.
- **Periodically**, the `Reconciler` GenServer runs a pass every 30 seconds (`config :testfleet, TestFleet.Execution.Reconciler, interval: 30_000`).
- Input: the active runs (with `cancel_requested_at` and `updated_at`), the containers labelled `TestFleet=true`, which runs have a process (`Execution.executing?/1`), and which run ids exist and are final.
- If Docker cannot be reached, the pass is skipped with a warning. The reconciler never guesses without Docker's answer.
- `recover: false` on the dispatcher and `enabled: false` on the reconciler keep both off in tests, except in the Docker tests.

## Reconciliation rules

First matching row wins. "Process" means a `RunExecution` registered for the run.

| # | Run | Process | Container | Action |
|---|-----|---------|-----------|--------|
| 1 | active | yes | any | Nothing; the process owns it. If `cancel_requested_at` is set, `Execution.cancel/1` again (idempotent). |
| 2 | active, cancel requested | no | present | Attach with `cancel: true`. |
| 3 | active | no | present | Attach: reattach to a running container, or finish an exited one. |
| 4 | active, cancel requested | no | missing | Finalize `cancelled`. |
| 5 | `preparing` | no | missing | Finalize `error`: "TestFleet lost the run while preparing it". At a periodic pass only when `updated_at` is older than 60 seconds: the dispatcher marks a run `preparing` a moment before its process registers. |
| 6 | `running` | no | missing | Finalize `error`: "container disappeared". |
| 7 | final | no | present | Remove the container. |
| 8 | no run row | – | this instance | Orphan: stop (grace period from its label) and remove, log a warning. |
| 9 | no run row | – | other or no instance | Nothing. |
| – | `queued` | – | – | Nothing; the dispatcher starts it. |

- A `preparing` run *with* a process is pulling and is bounded by the pull timeout (section 37).
- A finished run's container is left to its process while one exists: `RunExecution` reports the final status before removing its container, so that is the normal end, not a leftover.
- An attach re-reads the run just before starting the process, and skips it if the run finished or got a process since the pass read it.

Every failure below ends in the same place, a run that is active in PostgreSQL without a process, and the periodic pass turns each into a reattach within 30 seconds: a crashed `RunExecution` (a bug, a database error in the recorder), a process that gave up on an unreachable Docker (section 31), a cancel without a process.

## Attaching

`Execution.attach(run_id, opts)` finds `TestFleet-run-<run_id>` and inspects it:

| Container | Action |
|-----------|--------|
| running | Start `RunExecution` in attach mode |
| exited | Collect remaining logs, exit code, OOM flag, artifacts; finalize; remove |
| created, never started | Finalize `error`; remove |
| missing | Finalize `error` ("container disappeared") |

In attach mode, `RunExecution`:

1. reads the deadline, grace period, and secret keys from the container's labels, and the secret values from its environment
2. resumes the log stream with `since = runs.last_log_timestamp`, and **drops** every line whose timestamp is not newer, because `since` is inclusive and only second-precise across Docker versions
3. continues `sequence` from `runs.last_log_sequence + 1`
4. arms the deadline from `StartedAt`; if it has passed, stops the container immediately
5. continues the normal lifecycle (wait, collect, finalize, remove)

Lines that were buffered in memory when TestFleet stopped were never persisted, so `last_log_timestamp` does not cover them, and they are read again from Docker. A persisted line whose timestamp update was lost cannot happen: both are written in one transaction.

**Known edge case, accepted:** two distinct lines with the identical nanosecond timestamp, split exactly at the crash point, lose the second. Docker's timestamps make this practically impossible.

---

# 31. Docker and Database Failures

## Not admitting while Docker is unreachable

A run that is already preparing when Docker fails ends `error`. But with Docker down for ten minutes, admitting runs would turn every queued run into an error, including every scheduled run in that window. The dispatcher therefore checks Docker before admitting:

- Before a pass with queued runs, on its first pass, and on every pass while Docker is unreachable, it uses `Command.ping/0`, cached for 5 seconds.
- Unreachable: nothing is admitted; runs stay `queued`. It logs once when Docker goes down and once when it is back.
- The state is broadcast on `system` as `{:docker_status, %{reachable: boolean, since: DateTime, message: String.t() | nil}}` and kept in `:persistent_term` (written only on a change), so `Execution.docker_status/0` answers without waiting for a pass. Without a dispatcher, Docker counts as reachable.
- The dashboard shows a banner while Docker is unreachable; the queued runs panel says "waiting for Docker". The health endpoint reports Docker, but stays healthy (section 43). A notification goes out after 5 minutes (section 39).

## A broken stream is not the end of the run

After a Docker daemon restart with `live-restore`, or a restarted socket proxy, the suite may still be running. When the `wait` or `logs` stream ends with a transport error, `RunExecution` asks Docker again before finalizing. `TestFleet.Execution.Reconnect.decide/3` is the pure decision per answer:

1. `inspect` the container every 5 seconds, for up to 2 minutes (`:reconnect_interval`, `:reconnect_window`).
2. **Running** (`:follow`): drop both streams and open them again: logs `since` the newest frame consumed, deduplicated like a reattach, and a new `wait`. The deadline is unaffected. A stop (cancel or timeout) sent while Docker was away is sent again.
3. **Exited** (`:exited`): reopen the logs only (they end on their own), and finalize, with the fact `interrupted` (below).
4. **Missing** (`:missing`): finalize `error`: "container disappeared".
5. **Still unreachable after 2 minutes** (`:give_up`): flush the batch and stop **without finalizing**. The run stays active, and the reconciler reattaches once Docker answers.

A `logs` stream that ends normally while the container still runs is followed again the same way. The logs stream normally ends a moment before `wait`; that costs one extra `inspect`, which finds the container exited.

Logs resume after the **newest frame** consumed, not the last line reported: stdout and stderr lines complete in a different order than their frames arrived, and a long line spans several frames.

**Interrupted suites (rule 5a).** A Docker daemon restart without `live-restore` stops every container: the suite exits with 143, or 137 after the grace period, and by exit code alone would be `failed`. The fact `interrupted` is set when the process lost Docker (a stream broke with a transport error, or an `inspect` got no answer) and the next answer found the container exited. With a non-zero exit code, the run ends `error`: "Docker was interrupted while the suite was running (exit code N)". A suite that exited 0 meanwhile passed.

**Known limits:** a suite that failed on its own while the socket proxy was down also ends `error`, with an honest message; this is rare and accepted. When TestFleet was down during the interruption too, the reconciler finds an exited container and cannot know why; the exit code decides.

## Database failures while a run executes

When a write fails, the recorder raises and `RunExecution` crashes. No retries inside the process: an outage longer than a few seconds would block it either way, and one recovery path is easier to trust than two.

- The container keeps running, because a crashed `RunExecution` does not remove it.
- The next reconciler pass after the database is back reattaches. Output resumes from `last_log_timestamp`, so the lines of the failed batch are read again: nothing is lost, and nothing is stored twice (unique `(run_id, sequence)`).
- A failed `finish` is retried the same way: the reattach finds the exited container and finalizes again.

---

# 32. Concurrency

TestFleet limits concurrent executions:

```text
Global concurrency
        │
        ├── maximum 10 containers (MAX_CONCURRENT_RUNS)
        │
        └── environment limits (environments.max_concurrent_runs)
                │
                ├── Customer Portal / production: 1
                ├── Customer Portal / staging: 5
                └── Billing App / production: 1
```

The global limit is application configuration; environment limits are stored per environment.

The objective is to prevent E2E tests from overwhelming the execution server, browsers, target applications and their databases, production environments, and network infrastructure.

## Admission control

Limits are enforced by `TestFleet.Execution.Dispatcher`, one GenServer:

```elixir
config :testfleet, TestFleet.Execution.Dispatcher,
  max_concurrent_runs: 10,   # MAX_CONCURRENT_RUNS
  poll_interval: 5_000
```

**Wake-ups:** `{:run_created, _}` and `{:run_finished, _}` on the `runs` topic, and every 5 seconds as a safety net.

**A dispatch pass:**

1. If there are queued runs, check Docker (section 31); unreachable means nothing is admitted.
2. Count the active runs (`preparing`, `running`) in PostgreSQL, globally and per environment, so the counts survive restarts.
3. Load the queued runs oldest first, with their environment's limit.
4. For each queued run below both limits, and not held by the `queue` overlap policy (section 27):
   1. mark it `preparing` (conditional; skip it if it is no longer `queued`, for example just cancelled)
   2. build the request; on failure finalize it `error` with the reason
   3. start `RunExecution`; on failure finalize it `error`
   4. increase the counts
5. Leave all other runs queued.

A run blocked by its environment does not block runs of other environments (no head-of-line blocking). The run is marked `preparing` before its process starts, so the counts already include it, and a second pass cannot admit it twice.

Oban queue limits cannot provide this (section 13), and per-key limits are an Oban Pro feature.

The limits do not know organizations: in `:multi` mode, one organization can fill the global limit. Per-organization limits and fair admission across organizations come with the hosted edition (section 45).

In a multi-node setup, the dispatcher would run once per cluster (a globally registered process, or a PostgreSQL advisory lock). TestFleet runs as one node today.

In tests, the dispatcher is not started with the application; tests start it with `start_supervised!/1` and a fake engine.

---

# 33. Retry Policy

Failed E2E executions are **not** retried automatically. Otherwise flaky tests become hidden.

```text
max_attempts = 1
```

If retries are introduced later, each attempt must be visible:

```text
Run #1842

Attempt 1 → failed
Attempt 2 → passed
```

The history never hides the original failure.

This rule is about runs. Notification deliveries are retried (section 39).

---

# 34. Security Model

The execution subsystem is privileged. A test container may access internal networks and production systems, consume significant CPU and memory, execute arbitrary code, and use the credentials supplied to it.

TestFleet therefore implements:

- **Encryption at rest** for environment variable values, registry passwords, and notification secrets (section 6).
- **Secrets never reach the browser** after saving, and are redacted from `inspect`, logs, and Oban job arguments (which Oban stores as plain JSON; jobs carry ids only).
- **Secret masking** in stored and streamed logs (section 21).
- **Resource limits and mandatory timeouts** per test definition (sections 17, 24).
- **An isolated run network**, so test containers cannot reach PostgreSQL or the socket proxy (section 19).
- **Container hardening:** `no-new-privileges`, all capabilities dropped, never privileged, no host mounts (section 19).
- **A Docker socket proxy** (`tecnativa/docker-socket-proxy`) between TestFleet and the Docker socket, allowing only the endpoints TestFleet uses (section 43). Access to the raw socket is equivalent to root on the host; the proxy narrows what a compromised TestFleet process could do. Only the proxy mounts the socket.
- **Reliable cleanup** of containers (sections 29, 30).
- **Login on every page**, two roles, and no open registration (section 35).
- **API tokens** per user, stored hashed, revocable (section 38).
- **Untrusted artifacts:** safe extraction (section 11), JUnit without DTDs (section 10), and sandboxed delivery of HTML reports (section 41).
- **A hardened TestFleet container:** non-root, read-only file system, no capabilities (section 43).

**Accepted limitations** for the trusted internal deployment:

- Secrets are visible to anyone with `docker inspect` access on the host. A runner could use Docker secrets or tmpfs-mounted files instead (section 45).
- Docker API access remains highly privileged; the deployment is not an isolation boundary for an untrusted multi-tenant installation.
- Members can run any image against any environment; finer permissions (a viewer role, per-project permissions) are on the roadmap.
- There is no rate limiting of logins or API calls; TestFleet runs on an internal network behind a reverse proxy.

---

# 35. Organizations, Authentication, and Roles

## Organizations

An organization is a tenant. Everything users configure and run belongs to exactly one organization; users and their logins do not.

```text
organizations

id
name
slug            unique; lowercase a-z0-9-; not a reserved path segment
inserted_at
updated_at

memberships

id
user_id
organization_id
role            admin | member
inserted_at
updated_at      unique (user_id, organization_id)
```

| Belongs to an organization | Global |
|----------------------------|--------|
| projects, and through them environments, variables, test definitions, schedules, runs, logs, test results, artifacts | users, sessions and other user tokens, OIDC identities |
| registries | the instance id, Docker status |
| notification channels, and through them subscriptions and deliveries | retention, image cleanup, orphan cleanup |
| API tokens | the global concurrency limit |

`organization_id` is stored on the roots (`projects`, `registries`, `notification_channels`, `api_tokens`) and copied onto `runs` (section 7); the other tables reach their organization through their parent. Unique names are unique per organization: project slugs, registry hosts, channel names.

**Modes.** `config :testfleet, :organizations` is `:single` (the default) or `:multi`:

- **`:single`, self-hosted.** There is exactly one organization. The first-run setup creates it together with the first admin (it asks for the organization's name); an installation from before organizations gets one from a migration, named "Default" with the slug `default`, holding all existing data, with every user as a member in the role they had. Organizations cannot be created or deleted, and the UI has no organization switcher. Admins can rename the organization and change its slug.
- **`:multi`, the hosted edition.** A user can belong to several organizations, and the UI lets them switch. Signup, creating and deleting organizations, plans, and billing are part of the hosted edition (section 45), not of the core. In this mode, images are always pulled (section 37), and system notifications are not delivered to organizations (section 39).

**Reserved slugs** are the top-level path segments TestFleet uses or may use: `api`, `assets`, `auth`, `dev`, `fonts`, `health`, `images`, `live`, `organizations`, `phoenix`, `runs`, `setup`, `settings`, `users`, and the like (`TestFleet.Organizations.reserved_slugs/0`).

**The scope.** `TestFleet.Accounts.Scope` holds the user, and on organization pages the organization and the user's membership:

```elixir
%Scope{user: user, organization: organization, membership: membership}
```

`Scope.for_user/1` builds it at login; the `:org` route parameter adds the organization when the user is a member (`Scope.put_organization/3`). Not being a member of the organization in the URL is "not found", not "forbidden", so organization slugs cannot be probed. `Scope.admin?/1` reads the membership's role.

Every page is behind a login. Internal users log in with the company identity provider through OIDC where one is configured; TestFleet also has its own password login with invitations, so an installation without an identity provider stays usable. There is no open registration.

```text
first start, no users → /setup (one-time token from the log) → first admin
admin → invite (link, emailed when SMTP is set) → user sets a password or continues with the provider
anyone with an account at the identity provider → "Log in with <provider>" → member (if provisioning allows)
```

## Users

Generated with `mix phx.gen.auth` in `TestFleet.Accounts` and adapted. The scope is `TestFleet.Accounts.Scope`, assigned as `current_scope`.

```text
users

id
email               citext, unique
hashed_password     nullable: invited and OIDC-only users have none
confirmed_at
deactivated_at
last_login_at
inserted_at
updated_at
```

`users_tokens` holds sessions, magic links, email changes, and invitations (as generated, hashed). Passwords are hashed with `pbkdf2_elixir`: it needs no C compiler, so development on Windows and the Linux image use the same library.

Users are never deleted, because runs refer to them. An admin **deactivates** a user instead: login is refused, their sessions and API tokens are deleted, and their open LiveViews are disconnected (`UserAuth.disconnect_sessions/1`). A deactivated user can be reactivated. Deactivation is account-wide; in `:single` mode it is what an admin does on the Members page. Removing a member from one organization (`:multi`) deletes the membership and the user's API tokens of that organization, and disconnects their open pages. An organization's last active admin can neither be demoted, removed, nor deactivated (checked under a PostgreSQL advisory lock).

## Getting in

**First-run setup.** While there is no user, TestFleet logs on every start, at `warning` level (`TestFleetWeb.SetupNotice`):

```text
No users yet. Create the first admin at https://<PHX_HOST>/setup?token=<token>
```

The token is random, generated when the application starts, kept in memory, and new on every start. `/setup` without it, with a wrong one, or once a user exists answers 404. Because only someone who can read the container log can set up TestFleet, an empty installation cannot be taken over by the first visitor. The setup asks for the organization's name (optional, `Default` when empty; a name whose slug is reserved is refused), the admin's email, and a password, and creates the organization, the user, and the admin membership in one transaction under an advisory lock, so two submissions create one of each. A database that already has the organization (migrated) but no user does not ask for a name, and only creates the user and the membership. Setup with the identity provider names the organization `Default`; admins rename it afterwards.

**Invitations.** An admin invites someone by email and role on the Members page. That creates the user without a password, their membership in the organization with that role, and an invitation token (valid 7 days). The admin sees the link once, to copy; with SMTP it is also emailed. Opening the link asks for a password (or offers the provider); saving confirms the user and logs them in. An admin can replace a pending invitation's link or revoke it (which deletes the invited user and the membership). Inviting an email that already has an account into another organization (`:multi`) comes with the hosted edition.

**Login methods:**

| Method | Available when |
|--------|----------------|
| Email and password | `AUTH_PASSWORD_LOGIN` is not `false` (default: available) |
| Magic link | SMTP is configured (`SMTP_HOST`), for active users only |
| "Log in with `<OIDC_PROVIDER_NAME>`" | OIDC is configured |

`AUTH_PASSWORD_LOGIN=false` is refused at startup unless OIDC is configured, so TestFleet cannot be configured into a state without any way in. It makes TestFleet "SSO button only": the login, setup, and invitation pages offer only the provider, password and magic-link logins are refused by the session controller too, and the settings have no password section.

Changing one's email is only offered with SMTP. Setting or changing one's password, linking a provider, and creating API tokens need sudo mode (a login within the last 10 minutes).

The setup and invitation pages create the user, then post to `POST /users/log-in?_action=welcome` (`phx-trigger-action`), so the session is created by the controller like any password login.

**Release command.** For a lost or locked-out admin account:

```sh
docker compose exec testfleet bin/testfleet rpc 'TestFleet.Release.invite_admin("ops@example.com")'
```

It creates the user as an admin of the organization (`:single` mode), or makes an existing user an active admin, and prints an invitation link that sets a new password (invitation links therefore also work for existing users). It works regardless of `AUTH_PASSWORD_LOGIN`.

## Roles

Roles belong to the membership: a user can be an admin of one organization and a member of another.

| Area | Member | Admin |
|------|--------|-------|
| Dashboard, projects, test definitions, environments and their variables, schedules | ✓ | ✓ |
| Runs: run now, cancel, pin, logs, artifacts | ✓ | ✓ |
| Own settings and API tokens | ✓ | ✓ |
| Registries | – | ✓ |
| Notification channels, subscriptions, delivery log | – | ✓ |
| Members: invite, change role, deactivate (`:single`) or remove (`:multi`) | – | ✓ |
| Organization settings: name and slug | – | ✓ |

Registries and notification channels hold the most dangerous capabilities (credentials, and outgoing requests to arbitrary URLs), so only admins manage them. Roles are enforced at the edge: `TestFleet.Accounts.Scope.admin?/1`, the `:require_admin` `live_session` (a member is redirected to the dashboard with a flash), and controllers. The navigation hides what the user cannot open.

## Protected routes

- All LiveViews are in the `live_session`s `:require_authenticated_user` or `:require_admin`. Organization pages live under `/:org`; an `on_mount` hook (and a plug for controllers) resolves the slug to the user's membership, or answers 404.
- The log download (`/:org/runs/:id/log`) and artifacts (`/:org/runs/:id/artifacts/*name`) require a session and membership. The `:artifacts` pipeline authenticates like the browser pipeline, without `accepts html` (`<img>` and `<video>` requests do not accept HTML).
- Open: `/health`, the login pages, `/setup` (with its token), invitation links, `/auth/oidc` and its callback, static assets.
- The API authenticates with a bearer token only (section 38).
- An unauthenticated request is redirected to the login page and returns to the requested page after login.
- One test walks every route of the router, so a new route cannot be forgotten.

## OIDC

One provider, discovered from its issuer, configured by environment variables. The first targets are Microsoft **Entra ID** (`https://login.microsoftonline.com/<tenant-id>/v2.0`) and **AD FS** (`https://<adfs-host>/adfs`); Keycloak is used in development.

| Variable | Notes |
|----------|-------|
| `OIDC_ISSUER` | The issuer, as the discovery document names it |
| `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET` | A confidential client |
| `OIDC_PROVIDER_NAME` | The button label, default "single sign-on" |
| `OIDC_SCOPES` | Default `openid email profile` |
| `OIDC_EMAIL_CLAIM` | Default `email`; `preferred_username` (the UPN) is the usual alternative for Entra |
| `OIDC_USER_PROVISIONING` | Default `true`: unknown users get a member account on first login. `false`: only invited or linked users |
| `OIDC_ALLOWED_DOMAINS` | Optional, comma-separated: only these email domains get an account on first login |

The redirect URI is `https://<PHX_HOST>/auth/oidc/callback`.

**Library:** `oidcc`, the OpenID Foundation-certified implementation, called directly (no `oidcc_plug`), because the callback has several modes. It validates ID tokens, nonces, and issuers, and refreshes the provider's keys. The provider worker is started only when OIDC is configured, with `random_exponential` backoff (1 s to 1 min): its default would stop on a failed discovery and take TestFleet down with an unreachable provider. Until discovery succeeds, the button answers "single sign-on is not available right now". Client authentication prefers `client_secret_basic` and `client_secret_post` (TestFleet's client always has a plain secret). Pushed authorization requests are used when the provider offers them. Plain-HTTP issuers are allowed in development only.

**Flow:** authorization code with PKCE. `state`, `nonce`, the PKCE verifier, and the mode are kept in the session under `:oidc_request` and deleted on the callback, so a callback works once. The callback checks `state` first; the token exchange checks the nonce. Claims come from the ID token. An OIDC login is a session login without a remember-me cookie.

```text
user_identities

user_id
issuer
subject       the provider's sub: emails and UPNs change, sub does not
email         as last seen
inserted_at
updated_at
```

Unique `(issuer, subject)` and `(user_id, issuer)`.

**Modes:**

| Mode | Started from | On the callback |
|------|-------------|-----------------|
| `login` | the login page | the four cases below |
| `setup` | `/setup` with its token | creates the first admin with this identity, if the token is valid and there is still no user |
| `invite` | an invitation link | links the identity to the invited user and confirms them; the link is the authorization |
| `link` | the settings, in sudo mode (`/auth/oidc/link`) | links the identity to the logged-in user |

In `login` mode, in order:

1. **Known identity:** log that user in, unless deactivated; update the identity's email.
2. **Unknown identity, an existing user with that email, and `email_verified: true`:** link and log in (confirming a pending invitation).
3. **Unknown identity, no user with that email:** with provisioning on and the domain allowed, create an active, confirmed user, in `:single` mode as a member of the organization (in `:multi` mode without a membership; mapping a provider or domain to an organization comes with the hosted edition); otherwise refuse ("Ask an admin for an invitation", naming the allowed domains where they are the reason).
4. **Unknown identity, a user with that email, but not verified:** refuse, and explain invitation links and linking in the settings. Entra and AD FS do not send `email_verified`; linking by email would let anyone who can get a matching address or UPN take over the account.

A token without the email claim is refused with a message naming `OIDC_EMAIL_CLAIM`. Unlinking is allowed while another way in remains. No claim grants the admin role: admins are made by admins or the release command.

---

# 36. Registry Support

TestFleet does not assume a specific registry. A test definition stores an image reference; registry configuration is centrally managed in `registries` (section 6), matched by the image's host.

Authentication happens per pull through `X-Registry-Auth` (section 18). TestFleet never runs `docker login` and never writes a Docker config file.

Username/password and token authentication cover GitLab (deploy tokens), GitHub (personal access tokens), Docker Hub, and private OCI registries. Amazon ECR, whose tokens expire after 12 hours and must be fetched from AWS before each pull, is on the roadmap.

---

# 37. Images

## Pull policy

The request's `pull_policy`:

```text
auto        digest reference → if_missing, tag reference → always (default)
always      always pull
if_missing  pull only when the image is not present locally
never       use the local image; for locally built images such as the fixture suite
```

Under `auto`, a tag is pulled every time, so a moved tag is picked up; a digest is pulled only if missing. The digest is read from the local image after the pull (`RepoDigests`) and stored in `runs.image_digest`.

**Organizations on one Docker host.** Pulled images are cached host-wide. In `:multi` mode, a digest that one organization pulled with its credentials would otherwise be reused by another organization without any credentials. Runs therefore use `always` in `:multi` mode: every run pulls with its own organization's credentials, and a private image another organization cannot pull fails the run. The `PullCoordinator`'s key already includes the credentials, so concurrent pulls are never shared across credentials.

## Pull timeout

`config :testfleet, TestFleet.Execution, pull_timeout: :timer.minutes(10)` (`PULL_TIMEOUT_SECONDS`), separate from the run's timeout.

`RunExecution` arms a timer when it starts preparing; it covers the whole preparation (network, pull, inspect). When it fires, the prepare task is shut down and the run ends `error`: "image pull exceeded 10 min". `Command.pull/2`'s `receive_timeout` still catches a stalled connection; the pull timeout catches a pull that progresses too slowly. Docker may finish the abandoned pull in the background, which is harmless.

## One pull per image

`TestFleet.Execution.PullCoordinator` runs at most one pull per image at a time. When several runs need the same image, the first caller's pull is shared, and everyone gets its result, including an error.

- The key is the reference as configured **plus a hash of the credentials** (`:erlang.phash2/1`; the credentials are not kept), so a pull with wrong credentials never answers one with the right ones.
- Pulls run under `Execution.TaskSupervisor`, not in the caller: a caller is shut down on its pull timeout or a cancel, and the pull must outlive it. A caller that leaves only leaves the waiters. When the last waiter leaves, the pull is not cancelled (Docker cannot cancel a pull through the API).
- It deduplicates the pull only. Each run inspects the image and records its own digest.

## Image cleanup

Pulled test images accumulate on the host. A cleanup step (`TestFleet.ImageCleanup`, `IMAGE_RETENTION_DAYS`, default 7) removes only images TestFleet's runs recorded, by digest, never with a host-wide prune (the host may run other things):

- Candidates are the distinct `(image, image_digest)` pairs of runs, with the time of their latest run (`inserted_at`).
- **Kept:** pairs used by a run within the retention period, and the latest digest (the newest run's) of every image an enabled test definition references, whatever its age: it is what the next run starts from.
- **Removed:** every other pair, as `DELETE /images/<name>@<digest>` without `force`. That removes this reference; Docker deletes the image once nothing else references it. `404` counts as success; `409` (in use, or another tag) is skipped and tried again next hour.
- The local images are listed first, and `DELETE` is sent only for due references Docker still has; otherwise every hour would send a `DELETE` for every digest ever removed.
- Without Docker, the step is skipped with a warning.

Old digests of a mutable tag (`e2e:latest`, pulled every run) are exactly what accumulates; this removes them after a week.

---

# 38. API

The API lets a deployment pipeline start the E2E suite after it deploys, and wait for the result:

```text
CI pipeline: build app 1.4.2 and its E2E image 1.4.2 → deploy to staging
  ↓
PATCH /api/v1/projects/customer-portal/test-definitions/e2e   {"tag": "1.4.2"}
  ↓
POST  /api/v1/projects/customer-portal/runs                    {"test_definition": "e2e", "environment": "staging"}
  ↓  201, run 1842 (queued)
GET   /api/v1/runs/1842   … until "final": true
  ↓
pass or fail the pipeline on "status"
```

Updating the test definition's image is part of the API because the E2E image is versioned with the application: when the application moves to 1.4.2, its tests do too, for this run and for every scheduled run after it.

The user-facing reference is [testfleet.io/ci/api](https://testfleet.io/ci/api/); the CI guide and the wait-loop scripts (`deploy/ci/testfleet-run.sh`, `deploy/ci/testfleet-run.ps1`) are in [testfleet.io/ci/pipelines](https://testfleet.io/ci/pipelines/).

## API tokens

A token belongs to a user **and one organization**, and acts as that user's membership there. The organization is not part of the API's paths: a token only sees its organization's projects, runs, and test definitions, so the paths stay the same in both modes. Every endpoint is available to members; admin-only areas (registries, channels, members) have no API.

- **Format:** `tf_` followed by 32 random bytes, base64url without padding. The prefix makes tokens recognizable to secret scanners and people reading a CI log.
- **Storage:** `api_tokens`: `user_id` (`on_delete: :delete_all`), `organization_id`, `name`, `token_hash` (SHA-256 of the whole token, unique), `hint` (the last 4 characters), `expires_at` (nullable), `last_used_at`, timestamps. A token is high-entropy, so a fast hash is enough. The token itself is shown once, when created, and never stored.
- **Lifetime:** expiry chosen when creating (30 days, 90 days, 1 year, or never). Revoking deletes the row. Deactivating a user deletes their tokens; removing a membership deletes the tokens of that organization. A token whose user is no longer a member is refused. `last_used_at` is written only when older than 5 minutes, so a pipeline polling every few seconds does not write on every request.
- **Who manages them:** each user their own, in the settings, in sudo mode. The settings list the user's tokens of every organization they belong to; a new token is created for one of them (in `:single` mode, the organization). Admins cannot see or create other users' tokens; deactivating the user is how an admin cuts one off. The Members page shows how many tokens a member has.
- `api_tokens` are the first user-owned data, so their functions take the scope: `list_api_tokens(scope)`, `create_api_token(scope, attrs)`, `delete_api_token(scope, id)`.
- **CI without a person:** until service accounts exist, an admin invites a dedicated user (`ci@example.com`) and creates the token as that user, so the pipeline does not break when its author leaves.

## Authentication

```http
Authorization: Bearer tf_…
```

- `TestFleetWeb.APIAuth` reads only this header: no session, no cookies, so there is no cross-site request forgery to defend against, and a logged-in browser cannot call the API by accident.
- A missing, unknown, or expired token, or one whose user is deactivated: `401` with `WWW-Authenticate: Bearer`. The message does not say which.
- The plug assigns `current_scope` (the user, the token's organization, and the membership) and `api_token`.
- The `Authorization` header is never logged.

## Conventions

- **Base path `/api/v1`**: pipelines outlive TestFleet versions, and a version in the path lets a later incompatible change live next to the old one.
- **Addressing by slug** for projects, test definitions, and environments; by id for runs.
- **JSON** bodies, except the log (plain text) and artifact files.
- **Times** in ISO 8601, UTC.
- **Unknown fields** in a request body are refused (`422`), so a typo like `"enviroment"` fails loudly. A body sent as a form (`curl -d` without `Content-Type: application/json`) gets a `400` that says so.
- Errors raised before the router (a malformed JSON body) are rendered in the API's format: `render_errors` lists JSON first, so clients that accept `*/*` (curl) get JSON, while browsers still get HTML.
- Absolute URLs in responses come from the endpoint's configured URL (`PHX_HOST`).

**Errors:**

```json
{"error": {"code": "not_found", "message": "No environment \"stagign\" in project \"customer-portal\"."}}
```

| Status | `code` | When |
|--------|--------|------|
| 400 | `bad_request` | The body is not JSON, or not an object |
| 401 | `unauthorized` | No valid token |
| 404 | `not_found` | Unknown project, test definition, environment, run, or artifact; the message names which |
| 409 | `test_definition_disabled` | Starting a run of a disabled test definition |
| 410 | `expired` | The log or artifacts were removed by retention |
| 422 | `invalid` | Validation failed; `"details": {"field": ["message", …]}` |

## Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/projects/:project/runs` | Start a run |
| `GET` | `/api/v1/runs/:id` | A run's status and result |
| `POST` | `/api/v1/runs/:id/cancel` | Cancel a run |
| `GET` | `/api/v1/runs/:id/log` | The run's log, as text |
| `GET` | `/api/v1/runs/:id/artifacts` | The run's artifacts, as a list |
| `GET` | `/api/v1/runs/:id/artifacts/*name` | One artifact's file |
| `GET` | `/api/v1/projects/:project/test-definitions/:slug` | A test definition |
| `PATCH` | `/api/v1/projects/:project/test-definitions/:slug` | Update its image |

The log and artifact files are in their own `:api_files` pipeline without `accepts`, because curl fetches them without an `Accept` header; everything else is in `:api`. Controllers are in `TestFleetWeb.API`, with a fallback controller for the errors and shared lookups by slug and id (`TestFleetWeb.API.Lookup`), so "not found" messages are the same everywhere.

**Start a run:** `{"test_definition": "e2e", "environment": "staging"}` → `201 Created`, `Location: /api/v1/runs/1842`, and the run. It is `queued` and goes through the dispatcher like every other run; `trigger` is `api`, with the token's user and the token. `Runs.create_run/3` serves manual and API runs, with the same checks.

**A run:**

```json
{
  "id": 1842,
  "url": "https://testfleet.example.com/acme/runs/1842",
  "project": "customer-portal",
  "test_definition": "e2e",
  "environment": "staging",
  "trigger": "api",
  "triggered_by": "ci@example.com",
  "status": "failed",
  "final": true,
  "image": "ghcr.io/acme/portal-e2e:1.4.2",
  "image_digest": "sha256:…",
  "queued_at": "…", "started_at": "…", "finished_at": "…",
  "exit_code": 1,
  "error_message": null,
  "tests": {"passed": 41, "failed": 2, "skipped": 3},
  "log_url": "https://…/api/v1/runs/1842/log",
  "artifacts_url": "https://…/api/v1/runs/1842/artifacts"
}
```

`final` saves every client the list of final statuses. `tests` is `null` without JUnit. A pipeline should pass only on `passed`, and treat `failed` (the tests failed) differently from `error` and `timeout`.

**Cancel:** `202 Accepted` with the run; idempotent. An active run reaches `cancelled` once its container stopped, so the response may still say `running`.

**Log:** the stored, masked log as `text/plain`, streamed like the web download, with the truncation notice. `?after=<sequence>` returns only later lines, and every response carries `TestFleet-Log-Sequence: <last sequence sent>` (sent before the body), so a pipeline can print the log while it waits. The log ends at the last line stored when the request came in (`Runs.last_log_sequence/1`): a polling client neither misses nor repeats lines. Without new lines, the body is empty and the header repeats `after`. With `?after=`, the truncation notice is left out; the run's `log_truncated` says it instead.

**Artifacts:** the list carries `name`, `content_type`, `size_bytes`, and `url`. A file is sent with the same headers and range support as the web UI, always as an attachment; `TestFleetWeb.ArtifactResponse` serves both, so they cannot drift apart.

**Test definition:** `GET` returns `slug`, `name`, `project`, `image`, `enabled`, `updated_at`. `PATCH` takes exactly one of:

| Field | Example | Effect |
|-------|---------|--------|
| `image` | `"ghcr.io/acme/portal-e2e:1.4.2"` | Replaces the whole reference, validated like the form |
| `tag` | `"1.4.2"` | Keeps the repository, replaces the tag, drops a digest (`ImageRef.put_tag/2`). Validated as a Docker tag: `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}` |

Any other field is refused with `422`. The change goes through the form's changeset (`TestDefinitions.update_image/2`) and applies to runs created from then on; queued and running runs already copied their image.

**Concurrent pipelines.** Two pipelines that each update the image and then start a run can interleave, and one would test the other's image. The run's response names its image, so a pipeline can check it, and the CI guide recommends a concurrency guard (GitHub's `concurrency`, GitLab's `resource_group`). An image per run would remove the race (section 45).

---

# 39. Notifications

TestFleet tells people when something changes: a suite starts failing, recovers, or cannot run because of the infrastructure, and TestFleet itself stops scheduling or loses Docker. Messages go to email, Slack, Microsoft Teams, and generic webhooks.

**Notify on transitions, not on every run.** Alerting on every red run trains people to ignore alerts. A suite that stays red is reported once, and again when it recovers. `error` and `failed` are reported separately: an `error` is TestFleet's or the infrastructure's problem, a `failed` the application team's.

```text
run becomes final (one transaction with the status update)
  ↓ Oban job inserted in the same transaction
Notifications.EvaluateWorker: did this run change its series' state?
  ↓ one delivery per matching channel
Notifications.DeliveryWorker: email · Slack · Teams · webhook (retried)
```

## Channels

A channel is one destination. Channels belong to an organization and are managed by its admins.

| Kind | Target | Secret |
|------|--------|--------|
| `email` | 1–20 addresses | none (SMTP is server configuration) |
| `slack` | a Slack incoming webhook URL | the URL |
| `teams` | a Teams Workflows webhook URL (Adaptive Cards; the Office 365 connectors are retired) | the URL |
| `webhook` | any `http(s)` URL | the URL, and an optional signing secret (at least 16 characters) |

```text
notification_channels

name (unique), kind, enabled, email_recipients, url_encrypted, url_hint, signing_secret_encrypted, timestamps
```

**A webhook URL is a credential.** Slack's and Teams' URLs carry their token in the path. URLs and signing secrets are encrypted at rest (`redact: true`), never sent to the browser after saving (the list and the edit form show only `url_hint`, the host followed by `/…`; an empty URL field keeps the stored one), never logged (errors name the channel and the status, never the URL), and never in Oban job arguments. Slack and Teams URLs are not restricted to their vendors' hosts, so compatible services (Mattermost) work.

**Send test** sends a `test` event synchronously, not through Oban, from the saved channel or the form (an empty URL on the edit form uses the stored one), and shows "Delivered" or the error. Its results are shown, not stored.

## Subscriptions

```text
notification_subscriptions

channel_id, project_id (nullable), environment_id (nullable; requires project_id, of that project), events (array, at least one), timestamps
```

- A channel can have several subscriptions ("failing and recovered of project A", "errors of everything"). They are managed on the channel's page; a subscription is changed by removing it and adding another.
- A subscription's project and environment belong to the channel's organization; "All projects" means all projects of that organization.
- **System events** can only be chosen without a project. They concern the whole installation, so they are delivered only in `:single` mode; in `:multi` mode the operators monitor the installation themselves.
- An event matching several subscriptions of one channel is delivered once to that channel.
- Deleting a project or environment deletes its subscriptions; deleting a channel deletes its subscriptions and deliveries.

| Event | When | Scope |
|-------|------|-------|
| `run.failing` | A series turns red | project, environment |
| `run.recovered` | A red series turns green | project, environment |
| `run.error` | A run ends `error` after a run that did not | project, environment |
| `system.docker_unreachable` | Docker has been unreachable for 5 minutes | global |
| `system.docker_recovered` | Docker is reachable again, after an alert | global |
| `system.scheduling_stalled` | An enabled schedule is overdue by more than 10 minutes | global |
| `system.scheduling_recovered` | No schedule is overdue any more, after an alert | global |
| `test` | "Send test" | – |

New subscriptions preselect the three run events.

## Run events

A **series** is all runs of one test definition in one environment, of every trigger. Each final run has a **verdict**: `passed` is green; `failed` and `timeout` are red (a hanging suite is most often the application hanging); `error` has none (it says nothing about the application); `cancelled` is ignored entirely.

`TestFleet.Notifications.Transitions.event/2`, a pure function, compares a run that just became final with the earlier runs of its series, by id (runs of one series may finish out of order under `allow`):

| Run | The latest earlier run … | Event |
|-----|--------------------------|-------|
| red | with a verdict is green, or there is none | `run.failing` |
| red | with a verdict is red | nothing (still failing) |
| green | with a verdict is red | `run.recovered` |
| green | with a verdict is green, or there is none | nothing |
| `error` | not cancelled is not `error` | `run.error` |
| `error` | not cancelled is `error` | nothing (still broken) |
| `cancelled` | – | nothing |

So `passed → error → failed` reports the error and the failure, and the first run of a new suite reports only if it is red.

**Evaluation.** Every status update that makes a run final inserts a `Notifications.EvaluateWorker` job **in the same transaction**, so a final run is always evaluated, even if TestFleet dies right after the commit; PubSub is not used for this, because it is only transport. The worker loads the run and its series, decides the event, finds the matching subscriptions of **enabled** channels, and inserts one delivery per channel, each with its `DeliveryWorker` job, in one transaction. Deliveries are unique per `(channel_id, dedupe_key)` (`"run.failing:<run_id>"`), so a retried evaluation cannot notify twice.

**Known limit:** two runs of one series that run in parallel and both fail right after a green run can both report `run.failing`.

## System events

`TestFleet.Notifications.Watchdog`, a GenServer (not Oban: it must notice when Oban's cron is stuck), checks once a minute (`interval`, `docker_alert_after`, `schedule_alert_after`, `enabled`):

- **Docker:** `Execution.docker_status/0` unreachable for 5 minutes → `system.docker_unreachable`; reachable again after that alert → `system.docker_recovered`. Short outages, like a socket proxy restart, stay quiet. An episode is named by the dispatcher's `since`.
- **Scheduling:** enabled schedules of enabled test definitions whose `next_run_at` is more than 10 minutes in the past. While the tick works this never happens; the dashboard marks a schedule overdue after 2 minutes. Any found → **one** `system.scheduling_stalled` listing up to 10 ("Checkout on production (Customer Portal)", and "and N more"); none any more → `system.scheduling_recovered`. A stuck tick makes every schedule overdue at once, and one message says it better than fifty.
- An episode alerts once. Its state is kept in the process; after a restart during an outage, it alerts again. Accepted: simpler than persisting it. A failing check is logged and keeps the episode state.

**Heartbeat.** If TestFleet is entirely down, nothing runs and nothing fails, so nobody is alerted. With `HEARTBEAT_URL`, `TickWorker` sends `GET <url>` after each completed tick (in a task, 10 s timeout, no retries), for an external dead man's switch such as Healthchecks.io, which alerts when the pings stop. A failing ping is logged once per failure streak, never with the URL.

## Delivery

```text
notification_deliveries

channel_id, event, dedupe_key, run_id (nullable), data (system event facts; never secrets),
status (pending | sent | failed), attempts, last_error (short; never the URL or a body), sent_at, timestamps
```

`DeliveryWorker` (`max_attempts: 5`, Oban's backoff) renders the message from current data and sends it:

- `2xx` → `sent`
- `429`, `5xx`, transport errors → retried; `failed` after the last attempt
- other `4xx` (a revoked Slack URL answers `404` or `410`) → `failed` at once: retrying cannot help
- a channel disabled meanwhile, or a deleted run → `failed` with the reason

All HTTP uses `Req` with `retry: false` (Oban retries), `redirect: false`, and a 10-second timeout.

## Messages

`TestFleet.Notifications.Message` renders one struct per event (title, summary, facts, link); kind-specific formatters turn it into an email, Slack blocks, an Adaptive Card, or webhook JSON.

```text
Customer Portal E2E is failing on production
Failed after 4 min 12 s · 3 of 48 tests failed · scheduled run
First failures: checkout › pays with card, login › rejects wrong password, …
Previous run passed · Open run #1234
```

- The link is the run page, absolute, from `PHX_HOST`; system messages link to the dashboard and show times in `:default_timezone`.
- At most 3 failing test **names**, never failure messages or log output: they can carry data the team would not post to a channel.
- `run.error` includes the run's `error_message` (TestFleet's own text).
- Environment variables are never part of a message, not even their names.

**Formats:**

- **Email:** subject `[TestFleet] <title>`, plain text and simple HTML, from `SMTP_FROM`, all addresses in `To`.
- **Slack:** `{"text": <title>, "blocks": [...]}`, with an "Open run" button.
- **Teams:** an Adaptive Card 1.4 attachment with an `Action.OpenUrl`.
- **Webhook:** versioned JSON:

  ```json
  {
    "version": 1,
    "event": "run.failing",
    "delivery_id": 81,
    "occurred_at": "2026-09-28T14:02:11Z",
    "run": {"id": 1234, "status": "failed", "trigger": "schedule", "url": "https://…/acme/runs/1234",
            "started_at": "…", "finished_at": "…", "duration_ms": 252000, "exit_code": 1,
            "error_message": null, "tests": {"passed": 45, "failed": 3, "skipped": 0},
            "failed_tests": ["…"]},
    "previous_status": "passed",
    "test_definition": {"id": 7, "name": "Customer Portal E2E", "slug": "customer-portal-e2e"},
    "project": {"id": 2, "name": "Customer Portal", "slug": "customer-portal"},
    "environment": {"id": 5, "name": "production"}
  }
  ```

  System events carry `"system": {...}` instead. Headers: `X-TestFleet-Event`, `X-TestFleet-Delivery` (for idempotency on the receiver), and with a signing secret `X-TestFleet-Timestamp` and `X-TestFleet-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`.

## Email configuration

| Variable | Default |
|----------|---------|
| `SMTP_HOST` | – (without it, email is not configured) |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | none |
| `SMTP_TLS` | `if_available` (`always`, `never`) |
| `SMTP_FROM` | `testfleet@<PHX_HOST>` |

Development uses Swoosh's local adapter and `/dev/mailbox`; tests the test adapter. Without SMTP in production, email channels can be saved but show "Email is not configured on this server", and their deliveries fail with that message. SMTP also enables magic links, emailed invitations, and email changes (section 35).

Deliveries older than 90 days are deleted by the cleanup worker. Retrying deliveries does not conflict with the retry policy (section 33): that is about runs.

---

# 40. Retention

Without retention, videos and traces fill the disk within weeks.

```elixir
config :testfleet, TestFleet.Retention,
  artifacts_days: 30,   # ARTIFACT_RETENTION_DAYS
  logs_days: 90         # LOG_RETENTION_DAYS
```

```text
artifacts      30 days after finished_at
run_logs       90 days after finished_at
runs           kept indefinitely (small; they carry the history)
test_results   kept indefinitely (needed for per-test history)
deliveries     90 days
```

**Exceptions:**

- **Pinned** runs (a toggle on finished runs).
- The **latest run per test definition and environment whose status is `failed`, `timeout`, or `error`**, so the latest failure can always be investigated. "Latest" is by run id: a later passing run does not end the exception; a later failure does.

`TestFleet.Retention.run/1` (it takes `now`, for tests), called by the cleanup worker:

- **Expiring artifacts:** delete the run's directory, then its rows, then set `artifacts_expired_at`. The directory goes first: a crash in between leaves rows without files, which the page shows as missing, never files nobody can find.
- **Expiring logs:** delete the run's `run_logs` in batches of 10,000, then set `logs_expired_at`.
- At most 100 runs per job for each, oldest first, so a backlog shrinks over the next hours without long transactions.
- Only runs that still have artifacts (or log lines) are considered, so the page never claims something expired that never existed.
- Each expired run is broadcast as `{:run_updated, run}`, so an open run page clears its artifacts and log. The run page says when they expired; `GET /runs/:id/log` and the API answer `410 Gone`.
- Unpinning a run past its age lets the next job expire it. Active runs are never touched.

---

# 41. UI

Every page begins with `<Layouts.app>`, receives `current_scope`, and updates live where the data changes: runs through the `runs` and `run:<id>` topics, Docker through `system`, deliveries through `notifications`. Lists use LiveView streams. Forms are separate LiveViews (`ProjectLive.Form`), not modals; a form knows where it came from and returns there. Deleting asks for confirmation.

```text
/                                                 redirects to the user's organization
/:org                                             dashboard
/:org/projects, /new, /:slug, /:slug/edit
/:org/projects/:slug/test-definitions/new, /:id, /:id/edit
/:org/projects/:slug/environments/new, /:env, /:env/edit
/:org/projects/:slug/schedules/new, /:id/edit
/:org/runs, /:org/runs/:id                        runs list, run page
/:org/runs/:id/log, /:org/runs/:id/artifacts/*name    downloads
/:org/registries, /new, /:id/edit                 admin
/:org/notifications, /channels/new, /channels/:id/edit    admin
/:org/members                                     admin
/:org/settings                                    admin: name and slug
/runs/:id                                         redirects to /:org/runs/:id (links sent before organizations)
/organizations                                    the user's organizations
/users/settings                                   personal, no organization
/users/log-in, /users/invitations/:token, /setup
```

`/` opens the user's organization when they belong to exactly one (always, in `:single` mode); otherwise `/organizations` lists them to choose from, or says that there is none yet. Links TestFleet generates (notifications, API responses) contain the organization's slug. A changed slug breaks links that were sent with the old one; the run redirect at `/runs/:id` keeps working, because run ids are global.

## Dashboard

- **Figures:** Running (`preparing` + `running`), Passed today, Failed today, Timeouts today. "Today" is the calendar day in `:default_timezone` (on a DST change, the day starts when the clock jumps, or at the first midnight). Computed in one grouped query (`Runs.dashboard_stats/2`), on every run event and once a minute, so "today" rolls over at midnight.
- **Recent runs** (10), and **Queued runs**: the 10 that waited longest (they start first), the total as a badge, "and N more waiting".
- **Upcoming schedules:** the next six enabled schedules ordered by `next_run_at` (no cron parsing in the UI), leaving out those of disabled test definitions. A schedule more than 2 minutes overdue is marked **overdue**: scheduling is stuck. Reloaded every minute and when a scheduled run is created.
- A **Docker banner** while Docker is unreachable (section 31).

`TestFleetWeb.RunFeed` keeps the "newest runs" lists (runs list, dashboard, project and test definition pages) current: new runs go on top within the limit, and updates only touch runs that are shown.

## Project page

Test definitions (disabled ones dimmed with a badge), environments, schedules, and recent runs. Each schedule row shows its last tick: "Last run #1842 [status] · Sat 27 Sep 2026, 06:00 CEST", or a skip with its reason in a warning tone; the row refreshes when one of its runs changes. Times are shown in the schedule's timezone with the zone abbreviation; the UTC time is in the tooltip.

## Test definition page

Image, command, timeout, CPU, memory, shared memory, and the enabled state, with "Edit". **Run now** has one row per environment of the project, each with its own button, which creates the run and opens its page (disabled for a disabled test definition; without environments, a link to create one). Recent runs (20).

## Environment page

The variables, with one form above the list that adds a variable or edits the chosen one. Secret values show as `••••••` and are never sent to the browser.

## Run page

```text
Run #1842 · Customer Portal E2E · production · RUNNING
Started by ana@example.com (via "deploy pipeline")
Queued 06:00:01 · Started 06:00:03 · Duration 04:17
────────────────────────────────
Live output
   1  Starting Playwright
   2  Launching browser
   3  Login test  token=[MASKED]
────────────────────────────────
42 passed · 2 failed · 0 skipped
Artifacts: junit.xml, screenshots/, playwright-report/
```

- The status, test definition, environment, project, and trigger: "Started by `<email>`" for manual runs, "by `<email>` via `<token name>`" (or "via a revoked token") for API runs, "Schedule" with its cron expression and a link for scheduled runs, plus a "Scheduled for" row (it differs from the queued time after downtime or a `queue` wait).
- Queued, started, and finished times, and the duration, counting while the run is active.
- Image, digest, command, exit code, "memory limit exceeded" when OOM-killed, the error message, and the warnings.
- **Cancel** while the run is not final; "Cancelling…" from `cancel_requested_at`.
- **Pin** on finished runs.
- **Notifications:** "Sent to #e2e-alerts, QA email", or the failure.
- **Reconnect:** the page reloads its state from PostgreSQL and resumes receiving events. If the browser disconnects, execution continues normally.

**Log panel:**

- The page subscribes to `run:<id>` **before** loading the history (the last 1,000 lines, `Runs.list_log_tail/2`). Each line's DOM id is `log-<sequence>`, so a batch that overlaps the history updates lines in place instead of duplicating them.
- The lines are a stream with `limit: -2000`: a chatty suite cannot grow the page without bound. When earlier lines exist, a note links to the download.
- A colocated hook keeps the panel at the bottom while the user is there; scrolling up pauses following; "Jump to latest" resumes it.
- Monospace with line numbers, wrapped long lines, tinted stderr, `[MASKED]` as a badge, ANSI escape sequences stripped for display (stored unchanged).
- States: waiting to start, waiting for output, live (with a line count), no output, and the truncation notice ("Log limit of 50 MiB reached. Later output is shown while you watch, but not stored.").

**Log download:** `GET /runs/:id/log`: `text/plain; charset=utf-8`, `attachment; filename="run-<id>.log"`, in sequence order as stored, streamed from PostgreSQL in chunks of 1,000 lines (`Runs.reduce_log/3`), so a 50 MB log never sits in memory; a truncated log ends with the truncation line; `410` once expired.

**Tests panel** (with JUnit): the counts and total test time; failed and errored tests first with suite, class, name, duration, and message, the stack trace in a `<details>`; the other tests behind "Show all N tests", loaded on demand. `failed` and `error` differ in colour and icon.

**Artifacts panel:** the files as a tree with sizes and the total; images and videos previewed in a grid (at most 24) above the list, videos playing on click; an HTML file, or a directory with an `index.html`, gets "Open report". "Artifacts expired on …" after retention; nothing at all for a run without artifacts. Results and artifacts load once the run is final.

**Artifact downloads:** `GET /runs/:id/artifacts/*name`.

- The name is looked up in `artifacts` for that run; only stored names are served, and the request never builds a file path. Unknown → 404.
- `Content-Type` from the row, `X-Content-Type-Options: nosniff`. Images, videos, PDF, and text inline; other types as attachments.
- **`Content-Security-Policy: sandbox allow-scripts allow-popups allow-forms`** (no `allow-same-origin`) on every artifact except PDF. A report is someone else's HTML: sandboxed, it runs in an opaque origin and cannot reach TestFleet's cookies or pages, but scripts still run. SVG and XHTML run scripts too; images and videos are unaffected; browsers refuse to show a PDF in a sandboxed document. Relative links in a report work, because the route keeps the directory structure (each segment encoded on its own, `RunComponents.artifact_url/2`).
- **Known limit:** a report that needs `localStorage` fails in an opaque origin. A separate artifacts origin would be the complete fix (section 45).
- Single range requests are supported, so videos can seek; several ranges or a malformed header get the whole file.

## Runs list

The latest 50 runs, newest first, live: status, number, test definition, project and environment, trigger and who started it, start time, duration, and the test counts ("42 ✓ 2 ✗").

## Notifications page (admin)

Channels (name, kind, target or URL hint, enabled, latest delivery status; edit, send test, enable/disable, delete), each channel's subscriptions on its page (scope and event checkboxes; system events only for "All projects"; a new channel opens there: "Now choose what it receives"), and the last 50 deliveries, live.

## Members page (admin), organization settings, and personal settings

Members (`/:org/members`): active, invited, and deactivated members, with role, how they log in (password, provider), the number of API tokens, and last login; actions: invite, new link, revoke, change role, deactivate and reactivate (`:single`) or remove (`:multi`).

Organization settings (`/:org/settings`): the name and the slug, with a warning that links containing the old slug stop working.

Personal settings (`/users/settings`): password, email (with SMTP), linked provider, and the API tokens panel (name, organization, hint `tf_…a1B2`, created, expires, last used; "New token" shows the token once with a copy button; "Revoke").

The navigation shows the organization's name; in `:multi` mode it opens a switcher listing the user's organizations.

---

# 42. Failure Handling

| Situation | Result |
|-----------|--------|
| Registry unavailable, image does not exist, wrong credentials | `preparing → error`, with Docker's message |
| Docker unreachable before admission | runs stay `queued`; dashboard banner; alert after 5 minutes (section 31) |
| Docker unreachable while preparing | `preparing → error` |
| Docker interrupted while running | followed again within 2 minutes, otherwise the reconciler reattaches; an exited suite with a non-zero code ends `error` (rule 5a) |
| Container cannot start | `preparing → error` |
| Image pull exceeds the pull timeout | `preparing → error` |
| Container exceeds its memory limit (OOMKilled) | `running → error` |
| Test suite fails | `running → failed` |
| Test suite hangs | `running → timeout` |
| User cancels | `→ cancelled` |
| `RunExecution` crashes | the container keeps running; the reconciler reattaches within 30 s |
| TestFleet crashes or restarts | containers keep running; the startup pass reattaches them |
| LiveView disconnects | execution continues; the page reloads from PostgreSQL |
| Database temporarily fails | `RunExecution` crashes; the reconciler reattaches once the database is back, without losing or duplicating lines (section 31) |
| Container disappears | `error` ("container disappeared") |
| Artifacts over the limit | JUnit kept, the rest discarded, a warning on the run |
| Unparseable JUnit file | ignored, a warning on the run |

---

# 43. Deployment

TestFleet is **a containerized control plane that orchestrates independently running test containers**. The TestFleet container is not the test environment; it manages the test environments. One image, one Compose file, one `.env`. No Elixir on the server.

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

Installation and operation are documented for users at [testfleet.io/operate/install](https://testfleet.io/operate/install/) and in [deploy/README.md](../deploy/README.md).

## Image

Built from a Mix release (`mix phx.gen.release --docker`, adapted), in two stages on the same Debian release:

- **builder:** `hexpm/elixir` with the versions of `.tool-versions`; compiles the release with minified, digested assets.
- **runner:** `debian:<same>-slim` with the release only, plus `curl` for the health check, and `libsctp1` only to keep OTP's socket module from logging a warning on every start. Runs as `nobody`.

The image contains Erlang, the release, compiled assets, and the license (`/app/LICENSE`, AGPL-3.0). It does not contain PostgreSQL, test suite images, browsers, or test code; E2E containers are never baked into it. `/app/artifacts` exists in the image, owned by `nobody`, so a named volume mounted there is writable without setup.

Runtime configuration comes from environment variables; the image is never rebuilt per environment.

## Start

The image's command is `/app/bin/start`: it runs `bin/migrate`, then `exec`s `bin/server`. A failing migration stops the container before the application starts; Compose restarts it, and the logs show the error. `init: true` gives the BEAM a proper PID 1.

Stopping the container is safe at any time: running test containers keep running, and the reconciler adopts them on the next start (section 30).

**Upgrade:** set the new version in `TESTFLEET_IMAGE`, `docker compose pull && docker compose up -d`. Migrations run on start, while no other TestFleet runs, because there is only one. **Rollback:** the previous image, after `bin/testfleet eval 'TestFleet.Release.rollback(TestFleet.Repo, <version>)'` when the new version added migrations.

## Health

`GET /health` (and `HEAD`) is answered by a plug in the endpoint, before request logging, so the check every 30 seconds does not fill the log.

| Database | Response |
|----------|----------|
| `SELECT 1` succeeds | `200 {"status": "ok", "docker": "reachable" \| "unreachable"}` |
| fails | `503 {"status": "error", "docker": …}` |

Docker reachability is reported but does not make TestFleet unhealthy: restarting TestFleet does not fix Docker, and the dispatcher already holds runs while Docker is down.

## HTTP and the reverse proxy

TestFleet serves plain HTTP on port 4000 behind a reverse proxy (nginx, Traefik, Caddy) that terminates TLS, sets `X-Forwarded-Proto`, and passes WebSocket upgrades on `/live`. `force_ssl` is on (compile-time): requests without `X-Forwarded-Proto: https` are redirected, except for `localhost`, so the container's health check works. `PHX_HOST` is the public host name; links in notifications and API responses, and the WebSocket origin check, use it with `https` on port 443. The port is published on `127.0.0.1:4000` by default (`TESTFLEET_PUBLISH`).

## Compose

`deploy/compose.yaml` and `deploy/.env.example`, separate from the development `compose.yaml` in the repository root. The production Compose project is named `testfleet`, like the development one; on a development machine, run it with `-p` and another `TESTFLEET_PUBLISH`.

| Service | Image | Networks | Notes |
|---------|-------|----------|-------|
| `testfleet` | `${TESTFLEET_IMAGE:-ghcr.io/testfleetlabs/testfleet:latest}` | `backend`, `default` | Waits for a healthy `db`. `default` gives it egress (Slack, webhooks, SMTP, OIDC) and the published port. |
| `db` | `postgres:18-alpine` | `backend` | Named volume `db`; health check `pg_isready` |
| `docker-socket-proxy` | `tecnativa/docker-socket-proxy` | `backend` | Mounts the socket read-only, the only service that does. `CONTAINERS`, `IMAGES`, `NETWORKS`, `AUTH`, `POST` enabled; no published port. |

`backend` is `internal: true`: PostgreSQL and the proxy have no route out and no published ports. E2E containers run on `TestFleet-runs` and cannot reach `backend`.

The proxy's endpoints are exactly the ones `Docker.Command` uses: `_ping`, `version`, `auth`, `containers/*`, `images/*`, `networks/*`. Image builds and `commit` are not allowed.

## Configuration

| Variable | Required | Notes |
|----------|----------|-------|
| `PHX_HOST` | yes | Public host name |
| `SECRET_KEY_BASE` | yes | `openssl rand -base64 48` |
| `CLOAK_KEY` | yes | `openssl rand -base64 32`. **Back it up with the database.** |
| `POSTGRES_PASSWORD` | yes | URL-safe (`openssl rand -hex 24`), because it is part of `DATABASE_URL` |
| `TESTFLEET_IMAGE`, `TESTFLEET_PUBLISH` | no | Image (pin a version) and published address |
| `MAX_CONCURRENT_RUNS`, `RUN_LOG_LIMIT_MB`, `ARTIFACT_LIMIT_MB`, `ARTIFACT_RETENTION_DAYS`, `LOG_RETENTION_DAYS`, `PULL_TIMEOUT_SECONDS`, `IMAGE_RETENTION_DAYS`, `POOL_SIZE` | no | Limits and retention |
| `SMTP_*`, `HEARTBEAT_URL` | no | Section 39 |
| `AUTH_PASSWORD_LOGIN`, `OIDC_*` | no | Section 35 |

Compose sets `DATABASE_URL`, `DOCKER_HOST=tcp://docker-socket-proxy:2375`, and `ARTIFACTS_DIR=/app/artifacts` itself.

**Artifacts** live in the named volume `artifacts` at `/app/artifacts`: a named volume takes the ownership of the image's directory, so it works without a `chown` on the host. A host directory works too, mounted there and owned by UID 65534.

**What to back up:** the `db` volume (or a `pg_dump`), the `artifacts` volume, and `.env` (above all `CLOAK_KEY`). The TestFleet container holds nothing else; it is disposable.

## Hardening

The `testfleet` service runs as `nobody` with `read_only: true`, a `tmpfs` on `/tmp`, `cap_drop: [ALL]`, and `no-new-privileges`. It writes only to `/app/artifacts` and `/tmp` (`RELEASE_TMP=/tmp`, `ERL_CRASH_DUMP=/tmp/erl_crash.dump`). It never mounts the Docker socket.

## CI and publishing

`.github/workflows/ci.yml`:

| Job | What |
|-----|------|
| `check` | the checks of `mix precommit`, failing instead of fixing (compile with warnings as errors, unused dependencies, format, tests) |
| `docker` | the `:docker` integration tests against a real Docker Engine, with the fixture image and registry (section 44) |
| `image` | builds the image for `linux/amd64` and `linux/arm64`, each on a native runner (`ubuntu-latest`, `ubuntu-24.04-arm`), with layers cached in the GitHub Actions cache, and boots each with `deploy/compose.yaml`, generated secrets, and `docker compose up --wait`, then requests `/health`. A smoke test: the image builds, the release boots, migrations run on an empty database, and the proxy and networks are wired. |
| `publish` | on pushes only, after `check`, `docker`, and `image` are green: pushes each platform to `ghcr.io/testfleetlabs/testfleet` by digest, from the `image` job's cache, logged in with `GITHUB_TOKEN` (`packages: write`) |
| `manifest` | puts both digests under the tags (`docker buildx imagetools create`) |

| Git ref | Tags |
|---------|------|
| a commit on `main` | `main`, `sha-<short>` |
| the tag `v1.2.3` | `1.2.3`, `1.2`, `latest`, `sha-<short>` |
| a prerelease tag `v1.3.0-rc.1` | `1.3.0-rc.1`, `sha-<short>` |

A release tag must match the version in `mix.exs` (`v` + version), or `publish` fails before building. `docker/metadata-action` adds the OCI labels, including `org.opencontainers.image.source`, which links the package to the repository. `deploy/compose.yaml` has no `build:`; servers pull, and `.env.example` pins `TESTFLEET_IMAGE`, so an upgrade is a deliberate change.

`.github/workflows/docs.yml` builds the documentation site (`docs/`, Astro and Starlight) and deploys it to GitHub Pages; repository variables (`DOCS_SITE`, `DOCS_BASE`) set the custom domain.

---

# 44. Testing

`mix precommit` runs everything that does not need Docker. Tests follow the project's conventions: processes with `start_supervised!/1`, LiveView tests against element ids, no sleeping.

## Docker integration tests

Tests that drive real containers are tagged `@moduletag :docker` and excluded by default (`test/test_helper.exs`). Run them with:

```bash
mix test --only docker
```

They need the socket proxy (or a socket) in `DOCKER_HOST`, the fixture image, and the fixture registry, and fail fast with a message naming the missing piece. Shared setup is in `TestFleet.DockerCase`.

- The reconciler, broken-stream, and image cleanup tests are not async: a reconciler pass sees every container of this instance, and the broken-stream tests switch the Docker host for the whole application.
- Broken streams are tested through a TCP proxy (`TestFleet.DockerProxy`) that the test cuts and restores, like a restarted socket proxy.
- Database failures use a recorder that fails once (`TestFleet.FlakyRecorder`, through the dispatcher's `:engine_opts`).
- Duration assertions allow 500 ms of clock skew: durations are measured on Docker's clock, deadlines on TestFleet's, and Docker Desktop's VM clock can be a few hundred milliseconds off.
- The image cleanup tests make their own images by committing a container of the fixture image (with the Docker CLI: the proxy does not allow `/commit`) and pushing it to the fixture registry for a digest.
- A `pull_timeout` test pulls from a non-routable address (`10.255.255.1`), which hangs far beyond the test's timeout.

## The fixture suite

`test/support/fixtures/suite/` contains a `Dockerfile` (Alpine, a non-root user, `/TestFleet/artifacts` owned by it) and a `run.sh` that behaves according to `FIXTURE_MODE`:

| Mode | Behaviour |
|------|-----------|
| `pass` | prints to stdout and stderr, writes artifacts, exits 0 |
| `fail` | the same, exits 1 |
| `no_artifacts` | prints a line, writes no artifacts, exits 0 |
| `hang` | prints a line every second, never exits; traps `SIGTERM` (the script is PID 1, which ignores signals without a handler) |
| `ignore_term` | like `hang`, but ignores `SIGTERM`, forcing the kill path |
| `tick` | prints `tick 1`, `tick 2`, … for `FIXTURE_TICKS` seconds (default 5), then passes |
| `chatty` | prints 100,000 lines as fast as possible, including one 40 KB line |
| `partial` | prints output without trailing newlines |
| `oom` | allocates memory until the limit kills it |
| `env` | prints the `TestFleet_*` variables |
| `secret` | prints `FIXTURE_SECRET` in the middle of a line, on its own, and twice on stderr, and `FIXTURE_PLAIN` |
| `junit_pass` | writes passing and skipped tests, exits 0 |
| `junit_fail` | writes a failure and an error, exits 1 |
| `junit_swallow` | writes a failure, exits 0 (rule 6) |
| `junit_crash` | writes only passing tests, exits 1 (rule 9) |
| `junit_shards` | writes `junit/shard-1.xml` and `junit/shard-2.xml` |
| `big_artifacts` | writes a JUnit file and `FIXTURE_ARTIFACT_MB` MiB of data (default 5) |
| `unsafe_artifacts` | writes a symlink to `/etc/passwd` next to a normal file |
| `report` | a failing JUnit report, a PNG screenshot, and an HTML report whose script shows whether it runs sandboxed; exits 1 |

`run.sh` must keep LF line endings (`.gitattributes`). Tests that need an image without an artifacts directory, or a custom command, use `alpine:3` with `pull_policy: :if_missing`.

```bash
docker build -t testfleet/fixture-suite:dev test/support/fixtures/suite
```

After a change to the fixture, rebuild the image and push it to the fixture registry.

## The fixture registry

A local `registry:3` with htpasswd authentication on port 5055 (port 5000 is reserved on many Windows machines), in the development `compose.yaml` under the profile `registry`:

```bash
docker compose --profile registry up -d registry
docker tag testfleet/fixture-suite:dev localhost:5055/fixture-suite:dev
echo fixture-password | docker login localhost:5055 -u fixture --password-stdin
docker push localhost:5055/fixture-suite:dev
docker logout localhost:5055
```

Docker treats `localhost` registries as insecure by default, so no TLS is needed. The login is only for pushing the fixture; TestFleet itself never uses `docker login`. The credentials `fixture` / `fixture-password` are committed in `test/support/fixtures/registry/htpasswd`.

## Other development services

- The development `compose.yaml` runs PostgreSQL and the socket proxy (`tcp://localhost:2375`), which is also how Windows reaches Docker.
- The profile `oidc` adds Keycloak with an imported realm, a client, and two users (one with a verified email, one without), so the OIDC flow can be tried locally. Tests use `TestFleet.OIDCStub` instead, which encodes the ID token's claims in the authorization code and checks the nonce and the PKCE verifier like `oidcc` would.
- Outgoing HTTP of notifications and the heartbeat goes through `Req.Test` stubs in tests (`req_options`).

## Trying an image by hand

`mix testfleet.try` runs one container through the execution engine against the real Docker Engine, without the database or the UI, and prints the events as they arrive:

```bash
mix testfleet.try --image testfleet/fixture-suite:dev --env FIXTURE_MODE=chatty --timeout 60
mix testfleet.try --image alpine:3 -- sh -c "echo hello"
```

Options: `--env KEY=VALUE` (repeatable), `--timeout`, `--pull` (default `if_missing`), `--artifacts DIR`, `--username`/`--password`. This is for looking at behaviour by hand; the integration tests are the proof.

---

# 45. Roadmap

Not built, and kept possible by the architecture:

**The hosted edition**

TestFleet may also be offered as a hosted service, from the same repository: the open source core runs in `:multi` mode, and code under a commercial license (an `ee/` directory) adds what only the service needs:

- signup, creating and deleting organizations, inviting existing accounts into another organization, and mapping an identity provider or email domain to an organization
- plans, usage metering (test minutes), and billing
- per-organization concurrency limits, and fair admission across organizations in the dispatcher
- hosted runners: an execution backend on AWS ECS Fargate, one task per run, so suites of different organizations never share a host
- self-hosted runners (below) for targets in a customer's private network

**Execution**

- **Other backends.** `Execution` is an interface; ECS or Kubernetes implementations would replace `RunExecution`'s Docker calls without changing the product model.
- **Runners.** TestFleet owns the control plane; a runner could own the execution plane. A runner protocol would let TestFleet use dedicated runner servers, multiple Docker hosts, isolated execution networks, and runner pools. Each runner could advertise capacity, labels, location, network access, and resources, and the dispatcher would choose one (running once per cluster then). Runners could pass secrets as Docker secrets or tmpfs-mounted files instead of environment variables.

  ```text
                      TestFleet
                    Control Plane
                          │
                     Runner API
                          │
            ┌─────────────┼─────────────┐
            ▼             ▼             ▼
         Runner A      Runner B      Runner C
            │             │             │
         Docker        Docker        Docker
  ```

- **Amazon ECR**, whose tokens are fetched from AWS before each pull.
- **An image per run**, overriding the test definition's image for one API run, which removes the race between concurrent pipelines.
- **Visible retries**, if ever wanted: each attempt its own record (section 33).

**Storage and data**

- **Object storage** (S3, MinIO) for artifacts and very large logs, as a second `Artifacts.Storage` backend.
- **Partitioning** `run_logs` by month.
- **Per-test history and flakiness views**, on the existing `test_results` index.
- **Downloading all artifacts** of a run as one archive.
- **A separate artifacts origin** (`ARTIFACTS_ORIGIN`), so HTML reports that need `localStorage` work.
- **Key rotation** for `CLOAK_KEY`.

**Access**

- A read-only viewer role and per-project permissions.
- Service accounts, and token scopes (read-only, per project).
- Roles or groups from the identity provider's claims; several OIDC providers, SAML, LDAP.
- Per-user notification preferences.
- An audit log.

**Interfaces**

- **A CLI** on top of the API:

  ```bash
  testfleet run customer-portal production
  testfleet runs customer-portal
  testfleet logs 1842
  testfleet cancel 1842
  ```

- More of the configuration over the API (projects, environments, variables, schedules), test results over the API, and an OpenAPI document.
- Log search and filters, and rendering ANSI colours.
- Reminders for a suite that stays red, and batching several events into one message.

**Operations**

- **Metrics** for Prometheus/Grafana: `testfleet_runs_total`, `testfleet_runs_passed`, `testfleet_runs_failed`, `testfleet_runs_timeout`, `testfleet_run_duration_seconds`, `testfleet_running_executions`, `testfleet_container_errors`, `testfleet_queue_depth`, `testfleet_artifact_size_bytes`.
- Release automation (changelog, GitHub releases).

---

# 46. Core Architectural Principle

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

# 47. Product Philosophy

The core proposition can be summarized as:

> **Give TestFleet a Docker image. Tell it where and when to run it. TestFleet takes care of the rest.**

Or, more succinctly:

> **Tests belong to the application. Test execution belongs to TestFleet.**
