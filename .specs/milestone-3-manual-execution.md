# TestFleet — Milestone 3: Manual Execution

## 1. Purpose

Milestone 3 connects the configuration from Milestone 2 to the execution engine from the spike: "Run now" creates a run, the dispatcher admits it under the concurrency limits, `RunExecution` executes it, and the final status is stored.

```text
Run now
  ↓
Run (queued)
  ↓
Execution.Dispatcher (global and environment limits)
  ↓
RunExecution
  ↓
Docker Engine API (authenticated pull, create, start, wait)
  ↓
final status (main spec section 24)
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines runs (section 7), statuses (section 8), the decision table (section 24), per-run processes (section 27), the single pipeline (section 29), and admission control (section 34). This document records what the main spec leaves open, and where this milestone moves work between milestones.

Authentication is still deferred. Every run is `trigger = manual` without a user.

---

## 2. Scope

### In scope

- `runs` table and `TestFleet.Runs` context
- "Run now" on a new test definition page
- `Execution.Dispatcher` with the global and per-environment limits
- Building the execution request from the test definition, the environment's variables, and the registry credentials
- Persisting the run's lifecycle: status, container ID, image digest, start and finish times, exit code, OOM flag, error message
- Run page, runs list, dashboard figures, recent runs on the project page, all updated live through PubSub
- Deletion rules for projects, test definitions, and environments that have runs

### Moved into this milestone

Both are small because the spike already built them, and without them this milestone is not usable:

- **Cancellation** (main spec Milestone 7). A hanging suite would otherwise block its environment, whose limit defaults to 1, until its timeout.
- **Startup recovery**, a reduced form of the reconciler (main spec Milestone 7). A restart of TestFleet would otherwise leave runs in `preparing`/`running` forever, and they would count against the limits. See section 9.

### Out of scope

| What | Milestone |
|------|-----------|
| Persisting and streaming log lines, secret masking, log limit | 4 |
| Scheduled runs (`trigger = schedule`) | 5 |
| Artifacts and JUnit results (rules 6, 8, 9 of the decision table) | 6 |
| Periodic reconciliation, orphan containers, pull timeout, per-image pull lock, image cleanup | 7 |
| `runs.triggered_by_user_id` | with authentication |

Until Milestone 4, `RunExecution`'s output events are ignored. The run page shows no log yet.

---

## 3. Data Model

`runs` follows main spec section 7, with these decisions:

- **Foreign keys.**
  - `test_definition_id` and `environment_id` are `on_delete: :restrict`: run history must not disappear with its configuration.
  - `schedule_id` is nullable and `on_delete: :nilify_all`: deleting a schedule keeps its runs.
- **`triggered_by_user_id` is left out** until the `users` table exists (authentication). It is added then, nullable.
- **`trigger`**: `manual`, `schedule`, `api` (`Ecto.Enum`). Only `manual` is created in this milestone.
- **`status`**: the eight statuses of main spec section 8 (`Ecto.Enum`).
- **`image` and `command` are copied from the test definition when the run is created**, so the run records what it was asked to execute, even if the definition is edited while the run is queued.
  - Everything else is read when the run is started: timeout, resource limits, variables, and registry credentials.
  - A queued run therefore picks up a changed variable, but never a changed image.
- **`image_digest`**: the repo digest after the pull (main spec section 39). Null for locally built images without a repo digest.
- **`last_log_timestamp`** (bigint, nanoseconds): created now, written from Milestone 4.
- **Times**:
  - `queued_at`, `started_at`, `finished_at` are `utc_datetime_usec`.
  - `started_at` is the container's `State.StartedAt`, which is also what the deadline is derived from (main spec section 25). It is not TestFleet's clock.
- **Indexes**:
  - unique on `(schedule_id, scheduled_for)`
  - on `status` where the status is `queued`, `preparing`, or `running`
  - on `(test_definition_id, id)` and `(environment_id, status)`

Runs are shown as `#<id>`.

### Status transitions

Every transition is a conditional update (`WHERE status IN (...)`), so a late or repeated event can never reopen a finished run:

```text
queued     → preparing   dispatcher admits the run
queued     → cancelled   cancel before admission
preparing  → running     container started
preparing  → final       pull/create/start failed, or cancelled while preparing
running    → final       container exited, timed out, or cancelled
```

A final status is set together with `finished_at`, `exit_code`, `oom_killed`, and `error_message`, in one update.

### Deleting configuration

- A project, test definition, or environment with runs cannot be deleted. The context returns `{:error, :has_runs}`, and the UI shows a flash that explains it and suggests disabling the test definition instead. The foreign keys are the guarantee; the check provides the message.
- The confirmation texts on the delete buttons stay as they are. The check happens on delete.

---

## 4. `TestFleet.Runs`

```elixir
create_manual_run(test_definition, environment)   # {:ok, run} | {:error, :test_definition_disabled | :environment_mismatch}
get_run!(id)                                      # preloads test definition (with project) and environment
list_runs(opts)                                   # newest first; :limit, :project, :test_definition, :statuses
cancel_run(run)                                   # :ok, idempotent
has_runs?(project | test_definition | environment)
```

- `create_manual_run` reads the test definition again, so a definition disabled after the page was loaded is rejected. It also rejects an environment of another project. Nothing is user input here, so the errors are atoms, not changesets.
- **PubSub.** Every change broadcasts the run, with its test definition, project, and environment preloaded, on `run:<id>` and on the global topic `runs`:

  ```elixir
  {:run_created, run}
  {:run_updated, run}    # status or recorded facts changed
  {:run_finished, run}   # reached a final status
  ```

  This replaces the event names in main spec section 22, which is updated with this milestone. `{:run_output, lines}` follows in Milestone 4, on `run:<id>` only.

---

## 5. Dispatcher

`TestFleet.Execution.Dispatcher` is one GenServer, started in the application's supervision tree (main spec section 34).

**Wake-ups.** The dispatcher runs a dispatch pass on `{:run_created, _}` and `{:run_finished, _}` on the `runs` topic, and every 5 seconds as a safety net.

**A dispatch pass:**

1. Count the active runs (`preparing`, `running`) in PostgreSQL, globally and per environment.
2. Load the queued runs oldest first, with their environment's `max_concurrent_runs`.
3. For each queued run whose global and environment counts are below the limits:
   1. Mark it `preparing` (conditional; skip it if it is no longer `queued`, e.g. it was just cancelled).
   2. Build the request (section 6). If that fails, finalize the run as `error` with the reason.
   3. Start `RunExecution`. If that fails, finalize the run as `error`.
   4. Increase the counts.
4. Leave all other runs queued. A run blocked by its environment does not block runs of other environments.

The run is marked `preparing` before its process starts. The counts then already include it, and a second pass cannot admit it twice.

**Configuration:**

```elixir
config :testfleet, TestFleet.Execution.Dispatcher,
  max_concurrent_runs: 10,   # global; MAX_CONCURRENT_RUNS at runtime
  poll_interval: 5_000
```

**Tests.** The dispatcher starts runs through an engine module from configuration (`TestFleet.Execution` by default, main spec section 14). Unit tests use a fake engine that records requests and emits events on command. In the test environment the dispatcher is not started with the application; tests start it with `start_supervised!/1`.

**Isolation.** `TestFleet.Execution` stays free of test configuration below the dispatcher: `RunExecution` and `Execution.Docker.*` never touch the `Repo` or the configuration contexts. The dispatcher is the bridge. It reads runs through `TestFleet.Runs` and gets the request from `Runs.build_request/1`.

---

## 6. Building the Request

`Runs.build_request(run)` builds the `TestFleet.Execution.Request`:

| Request field | Source |
|---------------|--------|
| `run_id` | `runs.id` |
| `project_id` | the test definition's project |
| `environment_name` | the environment's `slug` (main spec: `TestFleet_ENVIRONMENT=production`) |
| `image`, `command` | the run (copied at creation) |
| `environment` | the environment's variables, decrypted |
| `secret_values` | the values of its secret variables (used for masking from Milestone 4) |
| `registry_auth` | `Registries.get_registry_for_image(image)`, or `nil` for an anonymous pull |
| `timeout_seconds`, `cpu_limit`, `memory_limit`, `shm_size` | the test definition |
| `pull_policy` | `:auto` (main spec section 39) |
| `stop_grace_seconds` | 30 |
| `artifact_path` | `nil` until Milestone 6: no artifacts are collected |

The request holds decrypted secrets. It is never logged, and `Request` redacts `environment`, `registry_auth`, and `secret_values` from `inspect`.

---

## 7. Recording Execution Events

`RunExecution` currently sends `{:run_event, run_id, event}` to a subscriber pid. This milestone adds a **handler**: a module implementing `TestFleet.Execution.Handler` (`handle_event(run_id, event)`), called inside the `RunExecution` process. `TestFleet.Runs.Recorder` is the handler that writes to the database. The pid subscriber stays as a handler for the spike tests and `Execution.run/1`.

The writes happen in the run's own process, so runs are recorded in parallel, and the dispatcher never waits for a database write.

| Event | Recorded |
|-------|----------|
| `{:status, :preparing}` | nothing (the dispatcher already set it) |
| `{:image_digest, digest}` | `image_digest` |
| `{:container_created, id}` | `container_id` |
| `{:running, started_at}` | `status = running`, `started_at` |
| `{:output, lines}` | nothing until Milestone 4 |
| `{:finished, result}` | final status, `finished_at`, `exit_code`, `oom_killed`, `error_message`, and `image_digest` / `container_id` if not yet set |

**Changes to `RunExecution`:**

- `{:status, :running}` becomes `{:running, started_at}` and carries the container's `StartedAt`.
- `{:finished, result}` is sent **before** the container is removed (main spec section 15: "finalize run → remove container"). If TestFleet dies between the two, the run is already final. The leftover container is removed by the reconciler (a finished run with a container, main spec section 32), and until Milestone 7 by the startup recovery. In the other order, the run would stay `running` without a container.

If a database write fails, the handler raises, and `RunExecution` crashes. The container keeps running and is picked up by the recovery on the next start. Handling database outages while running is Milestone 7.

---

## 8. Cancellation

`Runs.cancel_run(run)`:

- `queued` → `cancelled` directly (conditional update, `finished_at = now`).
- `preparing` / `running` → `Execution.cancel(run.id)`. `RunExecution` stops the container (SIGTERM, SIGKILL after the grace period), and the final status `cancelled` arrives through the recorder.
- final → `:ok`, nothing happens.

The run page has a "Cancel" button with confirmation while the run is not final. After a click on an active run, it turns into a disabled "Cancelling…" until the final status arrives, which can take the stop grace period (30 s). The state lives in the page only; a reload shows "Cancel" again. The main spec's `POST /api/runs/:id/cancel` comes with the API.

**Known gap:** an active run without a `RunExecution` process cannot be cancelled; `Execution.cancel/1` finds nothing and returns `:ok`. This happens in the short window between the dispatcher's `queued → preparing` and the process start, and after a restart whose recovery was skipped because Docker was unreachable. A persisted cancel request that the process (or the recovery) picks up closes this gap; it belongs to the reconciler work in Milestone 7.

---

## 9. Startup Recovery

Before its first dispatch pass, the dispatcher recovers the runs that were active when TestFleet stopped. At that point no `RunExecution` process can exist.

| Run status | Container `TestFleet-run-<id>` | Action |
|------------|-------------------------------|--------|
| `preparing` | missing | Finalize as `error`: "TestFleet restarted while preparing the run". The suite never started; the run is not retried (main spec section 35). |
| `preparing` / `running` | present | Attach (`Execution.attach/2`). It finishes an exited container, or keeps following a running one and enforces the original deadline. |
| `running` | missing | Finalize as `error`: "container disappeared". |
| final | present | Remove the container. |

When Docker cannot be reached, recovery is skipped with a warning, and the runs stay as they are until the next start. Recovery never makes a guess without Docker's answer.

Implementation (`TestFleet.Execution.Recovery`, run by the dispatcher in `handle_continue` before its first pass):

- Containers are found by the label `TestFleet=true` and matched to runs by `TestFleet.run_id` (`Execution.list_containers/0`).
- Runs that still have a `RunExecution` process are skipped. That happens when only the dispatcher restarted, not TestFleet; the process may be pulling an image, without a container yet.
- Containers without a run row are not touched. On a development machine, the dev and test databases share one Docker host. Removing orphans needs a way to tell instances apart and is part of the reconciler (Milestone 7).
- The test database starts run ids at 10^9 (`test/test_helper.exs`), so test containers cannot collide with dev containers of the same name.
- Attaching passes `last_log_timestamp`. The log sequence continues once logs are stored (Milestone 4).
- The dispatcher option `recover: false` turns recovery off; the test environment does, except in the Docker tests.

Milestone 7 turns this into the periodic `Execution.Reconciler` (main spec section 32), including orphans without a run row.

---

## 10. UI

```text
/projects/:slug/test-definitions/:id    test definition page (new)
/runs                                   runs list
/runs/:id                               run page
```

### Test definition page

- The details of main spec section 42: image, command, timeout, CPU, memory, shared memory, and the enabled state, with "Edit".
- **Run now:** one row per environment of the project, each with its own "Run" button. It creates the run and navigates to the run page.
  - Disabled test definition: the buttons are disabled, with a note.
  - No environments: an empty state that links to "New environment".
- **Recent runs** of this test definition (20).
- The project page's test definition rows now link here instead of to the edit form. Saving the edit form returns here; a new test definition still returns to the project.

### Run page (`/runs/:id`)

- `Run #1842`, the status, the test definition, the environment, the project, and the trigger.
- Queued, started, and finished times, and the duration. The duration keeps counting while the run is active (a one-second timer in the LiveView, only while active).
- Image, digest, command, exit code, "memory limit exceeded" when OOM-killed, and the error message.
- "Cancel" while the run is not final.
- Subscribes to `run:<id>` and updates live. On reconnect it reloads from PostgreSQL (main spec section 23).

### Runs list (`/runs`)

- The latest 50 runs, newest first, updated live from the `runs` topic.
- Shows status, number, test definition, project and environment, trigger, start time, and duration.
- Filters and pagination come later.

### Status presentation

- Every status has its own colour and icon.
- `failed` (tests failed) and `error` (infrastructure failed) must look clearly different.
- `preparing` and `running` show an animated indicator.

### Dashboard and project page

- The dashboard figures become real:
  - Running: `preparing` + `running`.
  - Passed today, Failed today, Timeouts today. "Today" is the calendar day in `:default_timezone`.
- "Recent runs" shows the latest 10. A new "Queued runs" panel lists the waiting runs.
- The project page gets a "Recent runs" panel (main spec section 42).
- All of them update live from the `runs` topic.

Implementation:

- `Runs.dashboard_stats/2` computes the figures in one grouped query. When midnight does not exist on a daylight saving change, the day starts when the clock jumps; when it exists twice, at the first one.
- The figures are recomputed on every run event, and once a minute so that "today" rolls over at midnight.
- "Queued runs" shows the 10 that have waited longest (they start first), the total as a badge, and "and N more waiting" below. The panel is reloaded when a queued run changes, so the next waiting run moves up.
- `TestFleetWeb.RunFeed` keeps the "newest runs" lists (runs list, test definition page, project page, dashboard) current: new runs go on top within the limit, and updates only touch runs that are shown. Before, an update of a run that had dropped off a full list appended it at the bottom.

---

## 11. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Runs: table, context, deletion rules, test definition page with "Run now", run page, runs list. Runs stay `queued`; queued runs can be cancelled. | – |
| B | Dispatcher and recording: admission control, request building, handler and recorder, `RunExecution` changes, live updates on run page and list. Runs execute. | A |
| C | Cancelling active runs, startup recovery. | B |
| D | Dashboard figures, recent and queued runs, recent runs on the project page. | A (live with B) |

Each slice passes `mix precommit` on its own.

**Status (2026-09-27):** all slices are built (227 tests, plus 46 Docker integration tests). The manual walkthrough (section 13) is pending.

---

## 12. Tests

- **`Runs`:** creation rules, conditional transitions (a late event does not reopen a finished run), cancel of a queued run, deletion rules, broadcasts.
- **`Runs.build_request/1`:** variables decrypted, secret values collected, registry matched, request `inspect` redacted.
- **Dispatcher** (fake engine): oldest first, global limit, environment limit, no head-of-line blocking, a run cancelled before admission is skipped, a failed request build or start finalizes as `error`, wake-up on `run_created` and `run_finished`.
- **Recorder:** each event results in the recorded fields and status.
- **Recovery** (Docker): each row of the table in section 9.
- **LiveViews:** test definition page, run now, run page live update, cancel, runs list, dashboard figures.
- **End to end** (Docker, `:docker` tag): "Run now" with the fixture image through the real dispatcher ends `passed`, a failing suite ends `failed`, an unknown image ends `error`, a private-registry image pulls with the stored credentials, and cancelling a running run ends `cancelled`.

---

## 13. Done

Milestone 3 is done when all slices pass `mix precommit` and the Docker tests, and a manual walkthrough works:

1. Run the private-registry fixture suite from the UI, and watch it go `queued → preparing → running → passed` on the run page.
2. Run a failing suite and see `failed`.
3. Cancel a running suite.
4. Start more runs than the environment limit allows, and see the extra ones wait in `queued`.
5. Restart TestFleet during a run, and see the run finish anyway.
