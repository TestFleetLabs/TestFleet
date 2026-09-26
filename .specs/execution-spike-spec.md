# TestFleet — Execution Spike Specification

## 1. Purpose

This spike proves that TestFleet can drive the whole container lifecycle of a test run from Elixir, through the Docker Engine HTTP API, before any product work starts.

It implements section 53 of [tech-architecture-execution-spec.md](tech-architecture-execution-spec.md) (the "main spec"). Section references below point to the main spec.

The spike is **not throwaway code**. The Docker client, the log decoder, the line buffer, and the per-run process become the foundation of `TestFleet.Execution`. What is deliberately left out is everything that needs the database, the UI, or the domain model.

---

## 2. Scope

### In scope

The seven capabilities from section 53:

1. **Start**: launch an arbitrary image
2. **Stream**: stream stdout/stderr, demultiplexed and split into lines
3. **Timeout**: stop a container after its deadline
4. **Cancellation**: cancel an active run from outside
5. **Artifacts**: copy a directory out of the stopped container
6. **Private registry**: pull with per-pull credentials and record the digest
7. **Reattach**: resume a run after its Elixir process was killed, without log gaps or duplicates

Plus the parts these depend on:

- the `TestFleet-runs` network (section 19)
- container naming, labels, resource limits, and hardening (sections 16, 17, 19)
- the final status decision for the rules that do not need JUnit (section 24)

### Out of scope

| Left out | Comes with |
|----------|-----------|
| Database persistence (`runs`, `run_logs`, `artifacts`) | Milestones 2–4 |
| `Execution.Dispatcher`, concurrency limits | Milestone 3 |
| PubSub, LiveView | Milestone 4 |
| Secret masking, log batching, log size limit | Milestone 4 |
| JUnit parsing (decision table rules 6, 8, 9) | Milestone 6 |
| Artifact size limit, storage backends | Milestone 6 |
| Periodic `Execution.Reconciler`, orphan cleanup | Milestone 7 |
| Concurrent-pull deduplication, pull timeout | Milestone 7 |
| Amazon ECR | later |

The spike's `RunExecution` sends events to a subscriber process instead of writing to PostgreSQL. That subscriber stands in for persistence, and the reattach step uses it as the "stored" state.

---

## 3. Environment

### Docker access

TestFleet reaches Docker through `DOCKER_HOST`:

```text
tcp://localhost:2375        → socket proxy from compose.yaml (default, required on Windows)
unix:///var/run/docker.sock → direct socket (Linux/macOS local development)
```

Windows named pipes (`npipe://`) are not supported. Req cannot talk to them, and the socket proxy covers this case.

The proxy in `compose.yaml` allows `CONTAINERS`, `IMAGES`, `NETWORKS`, and `POST`. `_ping` and `version` are allowed by the proxy's defaults. Image builds (`BUILD`) are **not** allowed, so fixture images are built with the Docker CLI (section 9).

### API version

All requests use a pinned API version prefix, `/v1.44` (Docker Engine 25+). `Client.ping/0` checks `GET /version` at startup and fails with a clear error when the daemon's `ApiVersion` is older.

### Configuration

```elixir
# config/runtime.exs
config :testfleet, TestFleet.Execution.Docker,
  host: System.get_env("DOCKER_HOST", "tcp://localhost:2375")
```

---

## 4. Module Layout

```text
lib/testfleet/execution.ex                      TestFleet.Execution            run/1, start/1, cancel/1, attach/2
lib/testfleet/execution/request.ex              TestFleet.Execution.Request    section 14
lib/testfleet/execution/result.ex               TestFleet.Execution.Result
lib/testfleet/execution/status.ex               TestFleet.Execution.Status     final status decision (pure)
lib/testfleet/execution/line_buffer.ex          TestFleet.Execution.LineBuffer (pure)
lib/testfleet/execution/run_execution.ex        TestFleet.Execution.RunExecution  GenServer, one per run
lib/testfleet/execution/docker/client.ex        TestFleet.Execution.Docker.Client        Req setup, errors
lib/testfleet/execution/docker/command.ex       TestFleet.Execution.Docker.Command       section 18 operations
lib/testfleet/execution/docker/log_decoder.ex   TestFleet.Execution.Docker.LogDecoder    frame demux (pure)
lib/testfleet/execution/docker/registry_auth.ex TestFleet.Execution.Docker.RegistryAuth  X-Registry-Auth header
lib/testfleet/execution/docker/image_ref.ex     TestFleet.Execution.Docker.ImageRef      parse host/repo/tag/digest
lib/mix/tasks/testfleet.spike.ex                mix testfleet.spike                       manual demo
```

The application supervision tree gets:

```elixir
{Registry, keys: :unique, name: TestFleet.Execution.Registry},
{DynamicSupervisor, name: TestFleet.Execution.Supervisor, strategy: :one_for_one}
```

`RunExecution` processes register as `{:via, Registry, {TestFleet.Execution.Registry, run_id}}` and start with `restart: :temporary` (section 27).

The spike does not need a database. `run_id` is an integer the caller supplies.

---

## 5. Docker Client

### `Docker.Client`

- Builds a `Req` request from `DOCKER_HOST`: `tcp://h:p` becomes `base_url: "http://h:p/v1.44"`; `unix://path` becomes `unix_socket: path` with `base_url: "http://localhost/v1.44"`.
- Disables Req's automatic retries. Docker operations are not blindly retryable.
- Normalizes errors to `{:error, %{status: integer | nil, message: String.t(), reason: term}}`. Docker returns `{"message": "..."}` bodies on errors; the message is surfaced as-is.
- Transport errors (proxy down, connection refused) become `{:error, %{status: nil, ...}}`. That is always an infrastructure `error` (section 24, rule 3).

### `Docker.Command`

One function per Engine API call. No other module builds Docker URLs.

| Function | Endpoint | Notes |
|----------|----------|-------|
| `ping/0` | `GET /_ping`, `GET /version` | version check |
| `ensure_network/1` | `GET /networks/{name}`, `POST /networks/create` | create if 404 |
| `pull/2` | `POST /images/create?fromImage=…&tag=…` | `X-Registry-Auth` header; see below |
| `inspect_image/1` | `GET /images/{name}/json` | `RepoDigests` for the digest |
| `create/2` | `POST /containers/create?name=…` | 409 = name already exists |
| `start/1` | `POST /containers/{id}/start` | 304 = already started, treated as `:ok` |
| `logs/2` | `GET /containers/{id}/logs?follow=1&stdout=1&stderr=1&timestamps=1&since=…` | streaming, `into: :self` |
| `wait/1` | `POST /containers/{id}/wait?condition=not-running` | streaming, `into: :self` |
| `inspect/1` | `GET /containers/{id}/json` | `State.ExitCode`, `State.OOMKilled`, `State.StartedAt` |
| `stop/2` | `POST /containers/{id}/stop?t=…` | 304 = already stopped, treated as `:ok` |
| `kill/1` | `POST /containers/{id}/kill` | 409 = not running, treated as `:ok` |
| `archive/2` | `GET /containers/{id}/archive?path=…` | tar stream to a temp file; 404 = no artifacts |
| `remove/1` | `DELETE /containers/{id}?force=true&v=true` | 404 treated as `:ok` |
| `list/1` | `GET /containers/json?all=true&filters=…` | by label `TestFleet=true` |

All "already in that state" responses are treated as success. This is what makes stop, kill, cancel, and cleanup idempotent (sections 26, 30).

Streaming calls (`logs`, `wait`) use `into: :self` with `receive_timeout: :infinity`, so the chunks arrive as messages in the `RunExecution` process and are handled in `handle_info/2` (`Req.parse_message/2`). No extra processes are needed to wait on Docker.

### Pull errors

`POST /images/create` returns `200` and then reports failures **inside** the JSON progress stream as `{"error": "...", "errorDetail": {...}}` (for example "unauthorized" or "manifest unknown"). `pull/2` must read the stream to the end and return `{:error, ...}` when any line contains `error`. A `200` status alone does not mean the pull worked.

### `Docker.RegistryAuth`

Encodes `%{username, password, serveraddress}` as JSON, then **URL-safe base64**, into the `X-Registry-Auth` header. Anonymous pulls send no header.

### `Docker.ImageRef`

Parses an image reference into host, repository, tag, and digest, using Docker's rules:

```text
e2e:1.17                                  → host docker.io, repo library/e2e, tag 1.17
registry.company.com/customer-a/e2e:1.17  → host registry.company.com
localhost:5000/spike-suite@sha256:…       → host localhost:5000, digest sha256:…
```

The first path segment is a host only if it contains `.` or `:`, or is `localhost`. This decides which registry credentials to use (section 38) and the pull policy (section 39): digest references are pulled only when missing locally; tag references are always pulled.

---

## 6. Log Streaming

### `Docker.LogDecoder`

Containers are created with `Tty: false`, so the log stream is multiplexed. Each frame is:

```text
byte 0      stream type: 1 = stdout, 2 = stderr
bytes 1–3   zero
bytes 4–7   payload length, big-endian uint32
payload
```

HTTP chunks do not align with frames. The decoder keeps the unconsumed bytes and returns complete frames only:

```elixir
{frames, decoder} = LogDecoder.feed(decoder, chunk)
# frames :: [{:stdout | :stderr, binary}]
```

### Timestamps

With `timestamps=1`, Docker prefixes every log message with an RFC 3339 nanosecond timestamp and a space:

```text
2026-09-26T10:15:03.123456789Z Running test 1...
```

The timestamp is parsed and kept as **integer nanoseconds since epoch**. Elixir's `DateTime` only keeps microseconds, and resuming the stream without duplicates needs the full precision.

### `LineBuffer`

Docker log messages are usually one line, but long lines are split into partial messages (16 KB), and a message may lack a trailing newline. The line buffer keeps one partial-line buffer **per stream** and emits a line only when it sees `\n`:

```elixir
{lines, buffer} = LineBuffer.feed(buffer, :stdout, timestamp_ns, "Running te")
{lines, buffer} = LineBuffer.feed(buffer, :stdout, timestamp_ns, "st 1...\n")
# lines :: [%{stream: :stdout, timestamp: ns, content: "Running test 1..."}]
```

A line's timestamp is that of its **first** fragment. When the stream ends, `LineBuffer.flush/1` emits any remaining partial lines. Content is kept as-is (bytes); invalid UTF-8 is replaced with `U+FFFD` at emit time. A trailing `\r` is stripped.

A partial line that grows past 1 MB without a newline is emitted as is. Otherwise a suite that prints progress with `\r` only would grow the buffer for its whole run.

Every emitted line gets the next `sequence` number from `RunExecution`.

---

## 7. `RunExecution`

A GenServer that owns one run from pull to removal. It sends events to a subscriber pid given at start:

```elixir
{:run_event, run_id, {:status, :preparing | :running}}
{:run_event, run_id, {:image_digest, "sha256:..."}}
{:run_event, run_id, {:container_created, container_id}}
{:run_event, run_id, {:output, [%{sequence, stream, timestamp, content}]}}
{:run_event, run_id, {:finished, %Result{}}}
```

In the product these events become database writes and PubSub broadcasts. In the spike they are the whole interface.

### Lifecycle

```text
init (handle_continue)
  ↓ ensure network TestFleet-runs
  ↓ resolve image, pick credentials by host
  ↓ pull (unless digest present locally)
  ↓ inspect image → image_digest
  ↓ create TestFleet-run-<id>
  ↓ start
  ↓ inspect → started_at, arm deadline
  ↓ open logs stream + wait stream
  ⋮ handle_info: log chunks, wait result, deadline, cancel
  ↓ wait returned
  ↓ drain remaining log chunks
  ↓ inspect → exit code, OOMKilled
  ↓ archive artifacts
  ↓ decide status, send {:finished, result}
  ↓ remove container
  ↓ stop
```

The image is pulled according to the request's `pull_policy`:

```text
auto        digest reference → if_missing, tag reference → always (default, main spec section 39)
always      always pull
if_missing  pull only when the image is not present locally
never       use the local image; for locally built images such as the fixture suite
```

The container is created with:

- `name` `TestFleet-run-<run_id>` and labels `TestFleet=true`, `TestFleet.run_id=<id>`, `TestFleet.project_id` (when set), `TestFleet.timeout_seconds`, `TestFleet.stop_grace_seconds`
- `Env` from the request, plus `TestFleet_RUN_ID`, `TestFleet_ENVIRONMENT`, `TestFleet_ARTIFACTS_DIR=/TestFleet/artifacts`
- `Cmd` only when `command` is non-empty (otherwise the image's own `ENTRYPOINT`/`CMD`)
- `Tty: false`, `HostConfig.AutoRemove: false`
- `HostConfig.NanoCpus`, `Memory`, `ShmSize` (default 2 GB)
- `HostConfig.MemorySwap` equal to `Memory`: otherwise Docker allows as much swap again, and a suite over its limit swaps instead of being OOM-killed
- `HostConfig.NetworkMode: "TestFleet-runs"`
- `HostConfig.SecurityOpt: ["no-new-privileges"]`, `CapDrop: ["ALL"]`, `Privileged: false`, no `Binds`

### Deadline

The deadline is `State.StartedAt + timeout_seconds`, read from the container after it starts. The spike has no database, so the container is the persisted source of `started_at`. This keeps the rule from section 25: a reattached process enforces the original deadline, never a fresh timer.

When the deadline fires: `stop` with the grace period (default 30 s, configurable per request so tests can use 2 s). Docker itself sends `SIGKILL` when the grace period ends; as a safety net, `RunExecution` sends `kill` if the container has still not exited 5 s later. The `stop` call blocks for up to the grace period, so it runs in a separate task and the process stays responsive. Artifacts are still collected.

The timeout and grace period are also stored as container labels, because an attaching process has no request (section 8).

### Cancellation

`TestFleet.Execution.cancel(run_id)` looks the process up in the registry and sends `:cancel`. The process stops the container the same way as a timeout and finishes with `cancelled`. A second cancel, or a cancel after the run finished, returns `:ok` and changes nothing. A cancel after the deadline already started stopping the container also changes nothing: the run stays `timeout`.

The pull runs in a task, so a cancel during `preparing` takes effect immediately: the task is killed and the run finishes as `cancelled` without creating a container.

### Artifacts

After the container stops, `archive/2` downloads `/TestFleet/artifacts` as a tar stream into a temp file, then extracts it with `:erl_tar` into the request's `artifact_path`. Docker puts the directory's contents under a top-level `artifacts/` entry, which is stripped. A 404 (directory missing) means no artifacts and is not an error. `Result.artifacts` lists the extracted files with relative path and size.

### Final status

`Execution.Status.decide/1` is a pure function implementing the decision table from section 24 without the JUnit rules:

| # | Condition | Status |
|---|-----------|--------|
| 1 | cancelled | `cancelled` |
| 2 | deadline expired | `timeout` |
| 3 | failed before the container started | `error` |
| 4 | `OOMKilled` | `error` ("memory limit exceeded") |
| 5 | container disappeared | `error` |
| 7 | exit code `0` | `passed` |
| 10 | exit code non-zero | `failed` |

### Cleanup

The container is removed in every outcome of the normal lifecycle, and `{:finished, result}` is sent only after that.

When `RunExecution` crashes, it does **not** remove its container. A `terminate/2` cleanup, as main spec section 30 suggests, would destroy a suite that is still running and could be reattached. Crash recovery belongs to reconciliation, which the spike covers through `attach/2`.

A `create` that fails with 409 means another execution owns the container. That run finishes as `error` and never touches the container.

---

## 8. Reattach

```elixir
TestFleet.Execution.attach(run_id,
  subscriber: pid,
  last_log_timestamp: ns,   # last timestamp the subscriber received
  next_sequence: n
)
```

`attach/2` finds `TestFleet-run-<run_id>` by name and inspects it:

| Container | Action |
|-----------|--------|
| running | start `RunExecution` in attach mode (below) |
| exited | collect remaining logs, exit code, OOM flag, artifacts; finish; remove |
| created, never started | finish as `error`; remove |
| missing | finish as `error` ("container disappeared") |

The timeout and grace period come from the container's labels. The artifact path is an option of `attach/2`.

In attach mode, `RunExecution`:

1. opens the log stream with `since=<last_log_timestamp in seconds.nanoseconds>`
2. **drops** every message whose timestamp is `<= last_log_timestamp`, because `since` is inclusive and has only second-level guarantees across Docker versions
3. continues `sequence` from `next_sequence`
4. arms the deadline from `State.StartedAt`; if it has passed, stops the container immediately
5. opens the wait stream and continues the normal lifecycle

Known edge case, accepted: two distinct lines with the identical nanosecond timestamp, split exactly at the crash point, lose the second line. Docker's log timestamps make this practically impossible.

---

## 9. Test Fixtures

### Fixture suite image

`test/support/fixtures/spike_suite/` contains a `Dockerfile` (Alpine, non-root user, `/TestFleet/artifacts` owned by that user) and a `run.sh` whose behaviour is chosen by an environment variable:

```text
SPIKE_MODE=pass      prints a few lines to stdout and stderr, writes artifacts, exits 0
SPIKE_MODE=fail      same, exits 1
SPIKE_MODE=no_artifacts  prints a line, writes no artifacts, exits 0
SPIKE_MODE=hang      prints a line every second, never exits
SPIKE_MODE=ignore_term  like hang, but traps and ignores SIGTERM (forces the kill path)
SPIKE_MODE=chatty    prints 100 000 lines as fast as possible, including one 40 KB line
SPIKE_MODE=partial   prints output without trailing newlines
SPIKE_MODE=oom       allocates memory until the limit kills it
SPIKE_MODE=env       prints the TestFleet_* variables
```

Built with:

```bash
docker build -t testfleet/spike-suite:dev test/support/fixtures/spike_suite
```

`hang` traps `SIGTERM` explicitly: the script runs as PID 1, which ignores signals it has no handler for. `run.sh` must keep LF line endings (`.gitattributes`).

Tests that need an image without an artifacts directory, or a custom command, use `alpine:3` with `pull_policy: :if_missing`.

### Private registry

A local `registry:3` with htpasswd authentication on port 5055, under a Compose profile so it only runs when needed. Port 5000 is reserved on many Windows machines.

```bash
docker compose --profile spike up -d registry
docker tag testfleet/spike-suite:dev localhost:5055/spike-suite:dev
docker login localhost:5055 -u spike && docker push localhost:5055/spike-suite:dev && docker logout localhost:5055
```

Docker treats `localhost` registries as insecure by default, so no TLS is required. The login is only for pushing the fixture; TestFleet itself never uses `docker login`.

Test credentials: `spike` / `spike-password`. The htpasswd file is committed under `test/support/fixtures/registry/`.

---

## 10. Tests

### Unit tests (always run)

Pure modules, `async: true`, no Docker:

- `LogDecoder`: single frame, several frames per chunk, frames split across chunks at every byte offset (including inside the 8-byte header), zero-length payload
- `LineBuffer`: complete lines, partial lines across feeds, interleaved stdout/stderr partials, `\r\n`, flush at end, invalid UTF-8
- `ImageRef`: the examples in section 5 and edge cases (`localhost/x`, port without dot, tag and digest together)
- `RegistryAuth`: header round-trips through URL-safe base64
- `Status.decide/1`: every row of the table, including precedence (cancelled beats OOM, timeout beats non-zero exit)

### Integration tests (need Docker)

Tagged `@moduletag :docker` and excluded by default in `test_helper.exs`, so `mix precommit` does not need Docker. Run with:

```bash
mix test --only docker
```

They fail fast with a message naming the missing piece when the proxy, the fixture image, or the registry fixture is unavailable. Shared setup and helpers live in `TestFleet.DockerCase`.

---

## 11. Steps and Acceptance Criteria

Each step is done when its criteria pass as integration tests (and unit tests for the pure parts).

### Step 1 — Start

- `Command.ping/0` succeeds through the proxy and reports the API version.
- `TestFleet-runs` network is created if missing and reused if present.
- `SPIKE_MODE=pass` finishes `passed` with exit code 0; `SPIKE_MODE=fail` finishes `failed` with exit code 1.
- `SPIKE_MODE=env` shows `TestFleet_RUN_ID` and the other reserved variables in its output.
- Starting the same `run_id` twice while the first is running returns an error; the suite does not run twice (409 on create).
- An image that does not exist finishes `error`, with the Docker message in `error_message`.
- With the proxy stopped, a run finishes `error` instead of crashing.
- After every run, no `TestFleet-run-*` container is left.
- The container is inspected in a test and has `CapDrop: ["ALL"]`, `no-new-privileges`, the memory limit, `ShmSize`, and the `TestFleet-runs` network.

### Step 2 — Stream

- `pass`: the subscriber receives all lines, correctly tagged stdout/stderr, with increasing `sequence`.
- `chatty`: all 100 000 lines arrive, in order, and the 40 KB line arrives as one line.
- `partial`: output without newlines is delivered at the end through `flush`.
- Log output continues to arrive while the container is still running (the first line arrives before the container exits).

### Step 3 — Timeout

- `hang` with a 3 s timeout finishes `timeout` within timeout + grace period + a small margin.
- `ignore_term` finishes `timeout` through the kill path.
- Artifacts written before the timeout are collected.

### Step 4 — Cancellation

- `cancel/1` on a running `hang` finishes `cancelled`.
- Calling `cancel/1` again, or after the run finished, returns `:ok` and does not change the result.
- Cancel during `preparing` finishes `cancelled` and no container is created.

### Step 5 — Artifacts

- `pass` produces the expected files (including a nested directory) in `artifact_path`, with correct contents.
- A suite that writes no artifacts finishes normally with an empty artifact list.

### Step 6 — Private registry

- Pulling `localhost:5055/spike-suite:dev` with correct credentials succeeds, and `Result.image_digest` is set to a `sha256:` digest.
- Wrong credentials finish `error` with the registry's message (the in-stream pull error from section 5).
- A digest reference that is already present locally is not pulled again; a tag reference always is.
- No Docker config file is written, and no global `docker login` happens. This holds by construction: credentials only exist in the per-request header.

### Step 7 — Reattach

- Start `hang`, collect some lines, kill the `RunExecution` process with `Process.exit(pid, :kill)`. The container keeps running.
- `attach/2` with the last received timestamp and next sequence resumes: the combined output before and after has no gaps and no duplicates, and `sequence` is continuous.
- Deadline enforcement survives the reattach: a run with a 5 s timeout, killed at 2 s and reattached at 3 s, still times out at about 5 s from its start.
- Reattaching after the deadline has passed stops the container immediately and finishes `timeout`.
- Container exited while no process was attached: `attach/2` finishes the run with the right exit code and the remaining logs.
- Container removed while no process was attached: `attach/2` finishes `error`.

### Also: OOM

- `oom` with a 64 MB memory limit finishes `error` with "memory limit exceeded".

---

## 12. Demo Task

`mix testfleet.spike` runs a single spike scenario against the real Docker daemon and prints the events as they arrive:

```bash
mix testfleet.spike --image testfleet/spike-suite:dev --env SPIKE_MODE=chatty --timeout 60
mix testfleet.spike --image alpine:3 -- sh -c "echo hello"
```

Options: `--env KEY=VALUE` (repeatable), `--timeout`, `--pull` (default `if_missing`), `--artifacts DIR`, `--username`/`--password`. This is for looking at behaviour by hand. The integration tests are the proof.

---

## 13. Done

The spike is done when:

- all criteria in section 11 pass with `mix test --only docker`
- `mix precommit` passes
- anything that turned out different from the main spec is written back into the main spec

## 14. Status

**Done (2026-09-26).** All criteria in section 11 pass (33 integration tests, repeated runs stable) against Docker Engine 29.3 through the socket proxy on Windows. `mix precommit` passes. Differences from the main spec have been written back to it (sections 14, 18, 19, 27, 30, 53).

Findings for the milestones:

- Req's `into: :self` works well for the log and wait streams: both arrive as messages in the `RunExecution` process, with no extra processes.
- `Result.finished_at` is TestFleet's clock when finalizing, not the container's `State.FinishedAt`. For durations close to the timeout this adds the time of artifact collection.
- Artifact extraction does not yet guard against symlinks in the tar stream; that belongs to Milestone 6 together with the size limit.
- `RunExecution` emits one `{:output, lines}` event per HTTP chunk. Through the socket proxy a chatty suite produced ~70 lines per chunk; over the Unix socket on CI the chunks are far smaller, down to single lines. Consumers must never append batches with `++` (this made a test helper quadratic and timed out CI), and the persistence path needs the 100 ms / 500 lines batching from main spec section 21.
- Each running run holds two long-lived HTTP connections (logs and wait). The Finch pool size must be checked against the global concurrency limit in Milestone 3.
