---
title: How execution works
description: The architecture behind a run, for the curious and for contributors.
---

This page explains what happens inside TestFleet between "run created" and "run finished". You do not need it to use TestFleet; it helps to reason about limits, restarts, and failures. The authoritative design is the [architecture specification](https://github.com/TestFleetLabs/TestFleet/blob/main/.specs/tech-architecture-execution-spec.md) in the repository.

## The pieces

```text
Browser ── LiveView ── Phoenix ──┬── PostgreSQL (source of truth)
                                 ├── Oban (schedule tick, cleanup, notifications)
                                 └── Execution.Dispatcher
                                        └── Execution.Supervisor
                                               └── RunExecution (one process per run)
                                                      └── Docker Engine API → E2E container
```

TestFleet is an Elixir application built with Phoenix and Phoenix LiveView. It talks to Docker over the Docker Engine HTTP API, never through the `docker` CLI.

- **Oban** decides **when a run is created**: the schedule tick runs every minute and creates queued runs for due schedules. Oban also runs cleanup and delivers notifications. It never executes a run.
- **The dispatcher** decides **when a run may start**. It admits queued runs, oldest first, under the global and per-environment limits. It wakes up when a run is created or finishes, and checks every 5 seconds as a safety net.
- **`RunExecution`**, one process per active run, owns the **running container**: pull, create, start, stream logs, enforce the deadline, handle cancellation, wait for the exit, collect artifacts, decide the status, clean up.
- **PostgreSQL** is the source of truth. Live updates go through Phoenix PubSub, but every log line and status change is written to the database first.

## A run's life

1. **Created**, `queued`: by Run now, the schedule tick, or the API. The image and command are copied from the test definition.
2. **Admitted:** when the limits allow, the dispatcher starts a `RunExecution` for it and the run becomes `preparing`.
3. **Pull:** the image is pulled with the matching registry's credentials (a tag every time, a digest only if missing). Concurrent runs of the same image share one pull. The resolved digest is stored on the run.
4. **Create and start:** a container named `TestFleet-run-<id>`, labelled as TestFleet's, on the `TestFleet-runs` network, hardened, with the environment's variables. The run becomes `running`, and `started_at` is the container's own start time.
5. **Stream:** output is split into lines, masked, buffered, and flushed every 100 ms or 500 lines: one database insert and one broadcast per batch. Chatty suites therefore cost little.
6. **Exit:** the container's exit code and its out-of-memory flag are read. The artifacts directory is copied out of the stopped container as a tar stream, capped at the size limit, and its JUnit files are parsed.
7. **Finish:** the [decision table](/guides/runs/#how-the-final-status-is-decided) sets the final status; status, test results, and artifact records are written in one transaction; notifications are evaluated in the same transaction. Then the container is removed.

## Deadlines

The deadline is `started_at + timeout`, both stored on the run, never a timer that starts fresh. A process that restarts or reattaches enforces the original deadline; if it has passed, the container is stopped immediately. The image pull does not count against the timeout; it has its own.

## Restarts and crashes

Containers run independently of the TestFleet process. At startup, and periodically after that, the **reconciler** compares the database with the containers labelled as TestFleet's:

| Run in the database                  | Container                    | Action                                                                                                                      |
| ------------------------------------ | ---------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `preparing` or `running`, no process | running                      | Reattach: resume the log from the last stored Docker timestamp, without gaps or duplicates, and keep enforcing the deadline |
| `running`                            | exited                       | Collect exit code, logs, and artifacts; finalize as usual                                                                   |
| `preparing` or `running`             | missing                      | Finalize as `error` ("container disappeared"), after a grace period for one still being created                             |
| `queued`                             | missing                      | Nothing; the dispatcher will start it                                                                                       |
| finished                             | still present                | Remove the container                                                                                                        |
| none                                 | labelled as this TestFleet's | An orphan: stop and remove it                                                                                               |

`try/after` cleanup in the run process is a best effort; the reconciler is what guarantees that nothing is left behind.

## Why Docker over HTTP

The Docker Engine API gives structured responses, streaming logs with timestamps, archive downloads, and per-request registry authentication, without parsing CLI output or writing credential files. All calls go through one module, which is also what the socket proxy's allow-list is based on.

## Not retried, on purpose

Runs are never retried automatically. A retry that passes hides a flaky test; TestFleet would rather show the failure. Notification deliveries are retried; runs are not.
