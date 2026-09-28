# TestFleet — Milestone 7: Reliability

## 1. Purpose

Milestone 7 makes execution survive what goes wrong around it: TestFleet restarting at any moment, Docker becoming unreachable, the database failing mid-run, a pull that never ends, a cancel that arrives while no process owns the run, and containers, images, and files left behind.

The rule behind every part is the one from Milestone 3: **PostgreSQL and Docker are the truth; processes are disposable.** Whatever a process fails to finish, a periodic pass that compares the two finishes it.

```text
every 30 s
  ↓
Execution.Reconciler: runs (PostgreSQL) × containers labelled with this instance (Docker)
  ↓
attach · finalize · cancel · remove · stop orphans
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines timeout handling (section 25), cancellation (26), cleanup (30), recovery and the reconciler (31–33), pull timeout, concurrent pulls, and image cleanup (39), and failure handling (44). Milestone 3 built cancellation and a startup-only recovery ([milestone-3-manual-execution.md](milestone-3-manual-execution.md), sections 8 and 9) and listed their known gaps. This document records what the main spec leaves open, and where the implementation deviates.

---

## 2. Scope

### In scope

- An instance identity on containers, so orphans can be told apart from another database's containers on the same Docker host
- `Execution.Reconciler`: the startup recovery, plus a periodic pass, plus orphans
- Persisted cancel requests, closing the Milestone 3 gap of an active run without a process
- Pull timeout, and one pull per image at a time
- Docker failures: not admitting runs while Docker is unreachable, following a run again after a broken stream, and telling a Docker interruption apart from a failing suite
- Database failures while a run executes
- Cleanup: unused images, orphaned artifact directories
- UI: Docker status on the dashboard, the "Cancelling…" state from the database

### Out of scope

| What | Milestone |
|------|-----------|
| Multiple TestFleet nodes, a cluster-wide dispatcher | later (main spec section 34) |
| Metrics (Prometheus) | later (main spec section 47) |
| Alerts about Docker or reconciliation problems | 8 |
| Pruning images TestFleet never pulled | never: the host may run other things |

---

## 3. Instance Identity

On a development machine, the dev and test databases share one Docker host, and a server may run a staging and a production TestFleet against one host. A container whose run id is missing from *this* database may be another instance's live run. Without telling instances apart, orphans cannot be removed (Milestone 3, section 9).

- A table `instance` with one row: `id` (UUID), `inserted_at`. The migration inserts it with `gen_random_uuid()`, so every database gets its own id without configuration. `TestFleet.Instance.id/0` reads it once and caches it in `:persistent_term`.
- New containers get the label `TestFleet.instance=<id>`. `Execution` stays free of the database: the id is passed in the `Request` (`instance_id`), like everything else.
- `Execution.list_containers/0` returns each container's `instance` label (or `nil`).
- **The reconciler only acts on containers with its own instance id.** Containers from before this milestone have no instance label. They are still matched to runs by `TestFleet.run_id`, as today, but never removed as orphans.

---

## 4. Reconciler

`TestFleet.Execution.Reconciler` replaces `Execution.Recovery`. It is a pure planner (`plan/2`) plus an executor, like `Recovery`, so the rules are tested without Docker.

### When

- **Startup:** the dispatcher runs a pass in `handle_continue` before its first dispatch, as it does today. No `RunExecution` process can exist yet, so no grace periods apply.
- **Periodically:** a `Reconciler` GenServer runs a pass every 30 seconds (`config :testfleet, TestFleet.Execution.Reconciler, interval: 30_000`). The first periodic pass is one interval after startup.
- `recover: false` on the dispatcher and `enabled: false` on the reconciler keep both off in the test environment, except in the Docker tests.

### Input

- Active runs (`preparing`, `running`), with `cancel_requested_at` and `updated_at`
- Containers labelled `TestFleet=true` with their state, run id, and instance label
- Which runs have a `RunExecution` process (`Execution.executing?/1`)
- Which run ids exist, and which are final

If Docker cannot be reached, the pass is skipped with a warning, as today. The reconciler never guesses without Docker's answer.

### Rules

First matching row wins. "Process" means a `RunExecution` registered for the run.

| # | Run | Process | Container | Action |
|---|-----|---------|-----------|--------|
| 1 | active | yes | any | Nothing; the process owns it. If `cancel_requested_at` is set, send `Execution.cancel/1` again (idempotent). |
| 2 | active, cancel requested | no | present | Attach with `cancel: true`: the process stops the container right away and finalizes `cancelled`, with artifacts. |
| 3 | active | no | present | Attach (reattach or finish an exited container). |
| 4 | active, cancel requested | no | missing | Finalize `cancelled`. |
| 5 | `preparing` | no | missing | Finalize `error`: "TestFleet lost the run while preparing it". At a periodic pass only when `updated_at` is older than 60 seconds: the dispatcher marks a run `preparing` a moment before its process registers. |
| 6 | `running` | no | missing | Finalize `error`: "container disappeared". |
| 7 | final | no | present | Remove the container. |
| 8 | no run row | – | this instance | Orphan: stop (grace period from its label) and remove, log a warning. |
| 9 | no run row | – | other or no instance | Nothing. |

**Deviations from main spec section 32:**

- Rule 5 uses the process registry, not the pull timeout: a `preparing` run *with* a process is pulling and is bounded by the pull timeout (section 6); one *without* a process is lost, whatever its age, once the dispatcher's short window has passed.
- Rule 7 skips runs that still have a process: `RunExecution` reports the final status before it removes its container, so a finished run with a container and a process is the normal end, not a leftover.

### Why periodic matters

Every failure below ends in the same place: a run that is active in PostgreSQL without a process. The periodic pass turns each of them into a reattach within 30 seconds, instead of waiting for the next restart:

- `RunExecution` crashed (a bug, a database error in the recorder)
- the process gave up on an unreachable Docker (section 7)
- a cancel arrived while no process existed (section 5)

---

## 5. Cancellation

**Known gap (Milestone 3, section 8):** an active run without a process cannot be cancelled; `Execution.cancel/1` finds nothing.

**Fix:** the request is persisted.

- New column `runs.cancel_requested_at` (`utc_datetime_usec`, nullable).
- `Runs.cancel_run/1`:
  - `queued` → `cancelled`, as before.
  - active → set `cancel_requested_at` (if not yet set), broadcast `run_updated`, then `Execution.cancel/1`. If no process exists, reconciler rules 1, 2, and 4 finish the job within one interval.
  - final → nothing.
- `Execution.attach/2` takes `cancel: true`: after adopting the container, the process begins the stop at once (it collects artifacts and finalizes `cancelled`, like any cancel).
- **Run page:** "Cancelling…" comes from `cancel_requested_at`, not from page state, so it survives a reload and shows in every open tab.

---

## 6. Pulls

### Pull timeout

`config :testfleet, TestFleet.Execution, pull_timeout: :timer.minutes(10)` (`PULL_TIMEOUT_SECONDS`).

- The `Request` carries `pull_timeout_ms`. `RunExecution` arms a timer when it starts preparing. When it fires before the image is ready, the prepare task is shut down and the run is finalized `error`: "image pull exceeded 10 min".
- The timeout covers `prepare_image` as a whole (network, pull, inspect), not only the HTTP request. `Command.pull/2`'s `receive_timeout` stays: it catches a stalled connection, the pull timeout a pull that makes progress too slowly.
- Docker may finish the abandoned pull in the background. That is harmless: the next run finds the image.

### One pull per image

`TestFleet.Execution.PullCoordinator` (a GenServer) runs at most one pull per image reference at a time.

- `PullCoordinator.pull(ref, auth)` starts a task for the first caller of a reference; later callers for the same reference wait for that task's result. Everyone gets the same result, including an error.
- The key is the reference as configured (`localhost:5055/suite:dev`, or with a digest) **plus a hash of the credentials** (`:erlang.phash2/1`; the credentials themselves are not kept). Callers of one reference normally send the same credentials, from the registry of the image's host; with the hash in the key, a pull with wrong credentials can never answer one with the right ones, or the other way round.
- The pulls run under `TestFleet.Execution.TaskSupervisor`, not in the caller: a caller's task is shut down on timeout or cancel, and the pull must outlive it. The coordinator and the task supervisor start before the run processes' supervisor, so they stop after them.
- A waiting caller that is shut down (its run's pull timeout, a cancel) only leaves the waiters; the pull goes on for the others. When the last waiter leaves, the pull is not cancelled: Docker cannot cancel a pull through the API anyway.
- It deduplicates the pull only. Each run inspects the image and records its own digest afterwards.

---

## 7. Docker Failures

### Not admitting while Docker is unreachable

Main spec section 44 says a run that cannot reach Docker ends `error`. That is right for a run that was already preparing. But with Docker down for ten minutes, the dispatcher would turn every queued run into an error, including every scheduled run in that window.

**Deviation:** the dispatcher checks Docker before admitting.

- Before a pass that has queued runs, the dispatcher uses the result of `Command.ping/0`, cached for 5 seconds. It also checks on its first pass, and on every pass while Docker is unreachable, queued runs or not: otherwise an outage without queued runs would never show, and a banner would never go away.
- Unreachable: nothing is admitted; runs stay `queued`. The dispatcher logs once when Docker goes down and once when it is back.
- The state is broadcast on the `system` topic as `{:docker_status, %{reachable: boolean, since: DateTime, message: String.t() | nil}}`, and `Execution.docker_status/0` returns the current one (the dispatcher's). The dispatcher keeps it in `:persistent_term`, written only on a change, so the dashboard reads it without waiting for a pass. Without a dispatcher, Docker counts as reachable.
- The ping is a dispatcher option (`:ping`), so the tests use a fake one.

### A broken stream is not the end of the run

Today, a failed `wait` stream finalizes the run: it ends `error` if Docker is gone, and the container is removed if Docker answers. After a Docker daemon restart with `live-restore`, or a restarted socket proxy, the suite may still be running.

**New:** when the `wait` or `logs` stream ends with a transport error, `RunExecution` asks Docker again before finalizing:

1. `inspect` the container, every 5 seconds, for up to 2 minutes.
2. **Running:** follow it again: logs `since` the last emitted line's timestamp (the same deduplication as a reattach, main spec section 32), and a new `wait`. The deadline timer is unaffected.
3. **Exited:** finalize, with the fact `interrupted: true` if the `wait` stream broke before the container exited (see below).
4. **Missing:** finalize `error`: "container disappeared".
5. **Still unreachable after 2 minutes:** the process flushes its batch and stops **without finalizing**. The run stays active, and the reconciler reattaches once Docker answers (rule 3).

A `logs` stream that ends normally (`:done`) while the container runs is followed again the same way. Today that loses the rest of the output.

As implemented:

- The decision per answer is `TestFleet.Execution.Reconnect.decide/3`, a pure function: `:follow`, `:exited`, `:missing`, `:retry`, `:give_up`.
- On a break, both streams are dropped and reopened together. For an exited container only the logs are reopened; they end on their own.
- Logs resume after the **newest frame** consumed, not after the last line reported: stdout and stderr lines are reported in the order they complete, so the last line can be older than one before it. Every consumed frame is reported, because a lost stream flushes the partial line.
  - Frames, not lines (changed during Milestone 8): a line longer than 16 KB spans several frames and carries its first frame's timestamp. Docker gives the frames of one line the same timestamp, so resuming after the line did not repeat them in practice (a Docker test with a 40 KB line passes either way); tracking frames makes that independent of Docker's timestamps.
  - The stored `last_log_timestamp`, which a reattach resumes from, is still the newest line's; for the same reason that is fine.
- The logs stream normally ends a moment before the wait stream. That now takes one extra `inspect`, which finds the container exited; the process reads the rest of the logs and finalizes as before, without logging a reconnect.
- A stop (cancel or timeout) sent while Docker was away is sent again once the container is followed again.
- `:reconnect_window` and `:reconnect_interval` are options of `Execution.start/2`, for the tests.

### Interrupted suites

A Docker daemon restart without `live-restore` stops every container: the suite gets `SIGTERM` and exits with 143, or 137 after the grace period. By exit code alone, that is rule 10: `failed`. But no test failed; the infrastructure did.

**New decision table rule** (main spec section 24), between rule 5 and rule 6:

| # | Condition | Status |
|---|-----------|--------|
| 5a | The `wait` stream broke with a transport error before the container exited, and the exit code is non-zero | `error`: "Docker was interrupted while the suite was running (exit code N)" |

Rules 1–5 (cancel, timeout, not started, OOM, missing) still win.

**Deviations, as implemented:**

- The fact is `interrupted`: the process lost Docker (a stream broke with a transport error, or an `inspect` got no answer), and the next answer found the container exited. A daemon going down may end the log stream cleanly before anything breaks; the unanswered `inspect` still marks it.
- Rule 5a applies only to a **non-zero** exit code. A suite that exited 0 while the socket proxy was down passed, and says so.
- It cannot tell a daemon restart from a suite that failed on its own while the socket proxy was down: both are an exited container after a lost connection. The second is rare and ends `error` with an honest message, so this is accepted.

**Known limit:** when the process was not attached during the interruption (TestFleet was down too), the reconciler finds an exited container and cannot know why; the exit code decides, as today.

### Database failures while a run executes

When a write fails, the recorder raises and `RunExecution` crashes (Milestone 3, section 7). Milestone 7 keeps that behaviour and relies on the reconciler:

- The container keeps running, because `RunExecution` does not remove its container when it crashes (main spec section 30).
- The next reconciler pass after the database is back reattaches (rule 3). Output is resumed from `last_log_timestamp`, so the lines of the failed batch are read again: nothing is lost, and nothing is stored twice (unique `(run_id, sequence)`).
- A failed `finish` is retried the same way: the reattach finds the exited container and finalizes again.

No retries inside the process: a database outage longer than a few seconds would block the process either way, and one recovery path is easier to trust than two.

A `:handler` in the dispatcher's `:engine_opts` now replaces the recorder, so a test can run a recorder that fails once (`TestFleet.FlakyRecorder`).

---

## 8. Cleanup

`TestFleet.Artifacts.CleanupWorker` (hourly, Milestone 6) runs three steps. Each is independent: a failure in one is logged and does not stop the others.

### 1. Retention (Milestone 6)

Unchanged.

### 2. Images

`config :testfleet, TestFleet.Execution, image_retention_days: 7` (`IMAGE_RETENTION_DAYS`).

TestFleet removes only images it pulled, and removes them by digest, never with a host-wide prune:

- Candidates are the distinct `(image, image_digest)` pairs of runs, with the time of their latest run.
- **Kept:**
  - pairs used by a run within `image_retention_days`
  - the latest digest of every image an enabled test definition references, whatever its age: it is what the next run starts from
- **Removed:** every other pair, as `DELETE /images/<name>@<digest>` (`Command.remove_image/1`, without `force`). That removes this reference; Docker deletes the image once nothing else references it.
  - `404` (already gone) counts as success.
  - `409` (a container uses it, or another tag) is skipped and tried again next hour.
- Old digests of a mutable tag (`e2e:latest` pulled every run) are exactly what accumulates. This removes them after a week.

As implemented (`TestFleet.ImageCleanup`):

- Runs are kept forever, so the list of pairs past their retention only grows. The cleanup therefore lists the local images first (`GET /images/json`, `Command.list_images/0`) and sends `DELETE` only for due references Docker still has. Without that, every hour would send a `DELETE` for every digest ever removed.
- "Latest digest of an image" is the digest of the newest run (highest id) of that image with a digest. "Used" is the run's `inserted_at`.
- A pair's reference is `ImageRef.name/1` plus `@digest`, the form Docker lists in `RepoDigests` (`alpine@sha256:…` for Docker Hub).
- Without Docker, the step is skipped with a warning.

### 3. Orphaned artifact directories

Directories under the artifacts root whose name is not the id of a run in this database, and `<run_id>.tar` / `<run_id>.extract` leftovers of an interrupted collection, are deleted.

- Only names that are entirely digits are considered; anything else in the root is left alone.
- A directory of an **active** run is never touched: it may be collecting right now.
- The artifacts root belongs to one instance (dev and test use different roots), so no instance check is needed.

As implemented (`TestFleet.Artifacts.Orphans`):

- Leftovers (`.tar`, `.extract`) are kept for every run that is not final, queued runs included: only a finished or unknown run's leftover is certainly from an interrupted collection.
- Names of more than 18 digits are no bigint, so no run id, and are left alone.
- `Orphans.run/1` takes the root, so its tests use their own directory instead of the shared test root.

---

## 9. UI

- **Dashboard:** while Docker is unreachable, a banner above the stats: "Docker is not reachable since 14:02. Queued runs wait until it is back." with the error message. It appears and disappears live (`system` topic).
- **Queued runs panel:** "waiting for Docker" instead of the usual note while Docker is unreachable.
- **Run page:** "Cancelling…" from `cancel_requested_at` (section 5). A run that ended through rule 5a shows its message like any error.

---

## 10. Data Model Changes

| Change | Purpose |
|--------|---------|
| Table `instance` (`id` UUID, `inserted_at`), one row inserted by the migration | Instance identity (section 3) |
| `runs.cancel_requested_at` (`utc_datetime_usec`, nullable) | Persisted cancel (section 5) |
| Index on `runs (image, image_digest)` where `image_digest IS NOT NULL` | Image cleanup candidates (section 8) |

---

## 11. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Reconciler: instance identity and label, `Execution.Reconciler` with the rules of section 4 at startup and every 30 s, orphans, persisted cancel requests, `attach(cancel: true)`, "Cancelling…" from the database. `Execution.Recovery` is removed. | – |
| B | Pulls: pull timeout, `PullCoordinator`. | – |
| C | Docker failures: the dispatcher's Docker check and the `system` topic, following again after broken streams, rule 5a, giving up without finalizing, the dashboard banner. Database failures: tests for the crash-and-reattach path. | A |
| D | Cleanup: images by digest, orphaned artifact directories. | – |

Each slice passes `mix precommit` and the Docker tests on its own.

**Status (2026-09-28): done.** All slices are built and tested (368 tests, plus 83 Docker integration tests), and the manual walkthrough of section 13 worked.

Notes from slice D: see section 8 ("As implemented") and section 12.

Notes from slice C: see sections 7 and 12 ("As implemented", "Deviations").

Notes from slice B:

- The pull timeout message formats the configured value: "image pull exceeded 10 min", "… 5 s".
- The Docker test for the timeout pulls from a non-routable address (`10.255.255.1`), which hangs until Docker's own connect timeout, far beyond the test's 1 s.
- Duration assertions in the Docker tests allow 500 ms of clock skew: durations are measured on Docker's clock (Milestone 6, section 5), deadlines on TestFleet's, and Docker Desktop's VM clock can be a few hundred milliseconds off. This made `stop_test` flaky once the suite grew.

Notes from slice A:

- The Docker tests start containers through `Execution.start/2` without an `instance_id`, so their containers carry no instance label and count as legacy: never removed as orphans. Containers the dispatcher starts carry the label.
- The integration tests of the reconciler are not async: a pass sees every container of this instance, and a container whose run sits in another test's sandbox would look like an orphan.
- An attach re-reads the run just before starting the process and skips it if the run finished or got a process since the pass read it.
- `attach(cancel: true)` on a container that already exited does not turn its outcome into `cancelled`: the suite finished on its own, and its result is kept.

---

## 12. Tests

- **`Reconciler.plan/2`:** every rule of section 4, including rule 5 at startup (no grace) and periodically (60 s grace), and legacy containers without an instance label.
- **Reconciler** (Docker): an orphan of this instance is removed; one with another instance id is not; a run whose process was killed is reattached by a periodic pass; a finished run's leftover container is removed.
- **Cancel:** a cancel while no process exists is persisted and finished by the reconciler, with the container stopped and artifacts collected; a cancel of a `preparing` run without a process ends `cancelled`; "Cancelling…" survives a reload.
- **Pull timeout:** a pull that does not finish in time (a short timeout, an image from a registry that does not answer) ends `error` with the message; the process does not wait for the pull task.
- **`PullCoordinator`:** concurrent callers of one reference cause one pull and all get its result; different references pull in parallel; an error reaches every waiter; a waiter that leaves does not affect the others.
- **Docker check:** with an unreachable Docker, the dispatcher admits nothing, broadcasts the status, and admits again when Docker is back (a fake engine and a fake ping).
- **Broken streams:** `Status.decide/1` for rule 5a and its precedence; the follow-again logic with a fake `Command` answering running, exited, missing, and unreachable; giving up leaves the run active.
  - As implemented: `Reconnect.decide/3` is tested without Docker. The Docker tests run the process through a TCP proxy (`TestFleet.DockerProxy`) that the test cuts and restores, like a restarted socket proxy: the log continues without gaps or duplicates; a container killed meanwhile ends with the rule 5a message; one removed meanwhile ends "container disappeared"; without an answer in time the process stops, the container keeps running, and a reattach finishes the run. These tests are not async: they switch the Docker host for the whole application.
- **Database failure:** a handler that raises once makes `RunExecution` crash with the container running; the next reconciler pass reattaches and the run finishes with all its lines exactly once.
- **Image cleanup:** the candidate query (kept and removed pairs); `Command.remove_image/1` against Docker with a fixture tag; `409` skipped.
  - As implemented: each Docker test makes its own image by committing a container of the fixture image, then pushes it to the spike registry to get a digest reference. The socket proxy does not allow `/commit`, and TestFleet never needs it, so this one fixture step uses the Docker CLI. The committed images are force-removed afterwards; the pushed tags (`localhost:5055/testfleet-cleanup:t…`) stay in the spike registry, which is test-only.
- **Orphaned directories:** removed; active runs', existing runs', and non-numeric names kept.
- **LiveViews:** the Docker banner appears and disappears; "Cancelling…" from the database.

---

## 13. Done

Milestone 7 is done when all slices pass `mix precommit` and the Docker tests, and a manual walkthrough works:

1. Start a `hang` run, stop the socket proxy (`docker compose stop docker-socket-proxy`) for 30 seconds, and start it again: the run keeps its log and continues; queued runs wait with the dashboard banner meanwhile and start afterwards.
2. Start a `hang` run and restart Docker (without `live-restore`): the run ends `error` with the "Docker was interrupted" message, not `failed`.
3. Start a `hang` run and kill only its process from `iex` (`[{pid, _}] = Registry.lookup(TestFleet.Execution.Registry, run_id); Process.exit(pid, :kill)`): the run is reattached within 30 seconds and its log continues without gaps. Then cancel a run whose process was just killed: it ends `cancelled` after the next pass, and the page shows "Cancelling…" until then, also after a reload.
4. Create a container with the dev instance's label and an unknown run id (`docker run -d --label TestFleet=true --label TestFleet.run_id=999999 --label TestFleet.instance=<id> alpine sleep 600`): it is removed within 30 seconds. The same without the instance label stays.
5. Set a pull timeout of 5 seconds and run an image that is large and not cached: the run ends `error` with the pull timeout message.
6. Set `IMAGE_RETENTION_DAYS=0`, run the cleanup, and see old digests of the fixture image removed while the latest one stays.
