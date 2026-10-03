---
title: Runs
description: Follow a run live, read its log and results, cancel it, and understand its final status.
---

A run is one execution of a test definition against an environment. It is created by **Run now**, by a [schedule](/guides/schedules/), or through the [API](/ci/api/), and all three take the same path:

```text
queued ──► preparing ──► running ──► passed | failed | timeout | error
   │            │            │
   └────────────┴────────────┴──► cancelled
```

1. **queued:** the run exists and waits until the [concurrency limits](/guides/environments/#concurrency) admit it.
2. **preparing:** TestFleet pulls the image (with the registry's credentials) and creates the container.
3. **running:** the container executes the suite. Its output streams to the run page.
4. When the container exits, TestFleet collects the artifacts, reads the JUnit reports, decides the final status, and removes the container.

## The run page

`/runs/<id>` shows, live:

- the status, the duration, and what started the run: "Manual by ana@example.com", the schedule with its cron expression and the slot it was scheduled for, or "API by ci@example.com via deploy-pipeline" with the token's user and name
- the image as configured, and the digest it resolved to
- the log, line by line as the suite writes it, with stderr lines highlighted
- once finished: the tests (failed first) and the artifacts, see [Results and artifacts](/suites/results-and-artifacts/)
- the notifications the run caused, if any

The page can be closed at any time: the run continues on the server, and reopening the page shows everything so far and continues live.

### The log

Every line is stored, with secret values [masked](/guides/environments/#secrets). **Download** gives the whole log as text.

Each run stores up to 50 MiB of log (`RUN_LOG_LIMIT_MB`). Beyond that, TestFleet stops storing lines and marks the log as truncated; an open run page keeps showing the newest output live. A suite that hits the limit is usually printing far more than anyone can read; turn down its verbosity.

Logs are kept for 90 days by default; see [retention](/suites/results-and-artifacts/#retention).

## Cancelling

**Cancel run** on the run page (or `POST /api/v1/runs/:id/cancel`):

- a **queued** run is cancelled at once
- an **active** run's container is stopped: `SIGTERM`, then `SIGKILL` after 30 seconds. The run becomes `cancelled` once the container has stopped, and artifacts written so far are kept.

Cancelling twice, or cancelling a finished run, changes nothing.

## Timeouts

When a run exceeds its test definition's timeout, it is stopped the same way and ends `timeout`. The deadline is the container's start time plus the timeout, stored with the run: a TestFleet restart does not reset it, and time TestFleet spent down counts.

## How the final status is decided

The exit code alone cannot separate a failing test from a broken infrastructure, so TestFleet combines what it knows. The first matching rule wins:

| #   | Condition                                                                          | Status                                        |
| --- | ---------------------------------------------------------------------------------- | --------------------------------------------- |
| 1   | The run was cancelled                                                              | `cancelled`                                   |
| 2   | The timeout expired                                                                | `timeout`                                     |
| 3   | Something failed before the container started: registry, pull, create, start       | `error`                                       |
| 4   | Docker killed the container for exceeding its memory limit                         | `error` ("memory limit exceeded")             |
| 5   | The container disappeared while running                                            | `error`                                       |
| 5a  | TestFleet lost Docker while the suite ran, and the suite exited non-zero meanwhile | `error` ("Docker was interrupted")            |
| 6   | Exit code `0`, but the JUnit report has failures or errors                         | `failed`                                      |
| 7   | Exit code `0`                                                                      | `passed`                                      |
| 8   | Exit code non-zero, and the JUnit report has failures                              | `failed`                                      |
| 9   | Exit code non-zero, JUnit report present, but no failures in it                    | `error` (the suite crashed outside its tests) |
| 10  | Exit code non-zero, no JUnit report                                                | `failed`                                      |

Why some of these rules exist:

- **Rule 6** catches suites that swallow their own exit code.
- **Rule 9** catches crashes in setup, teardown, a reporter, or the runner itself. These are not test failures, and calling them `failed` would send someone looking for a bug in the application.
- **Rule 10** says `failed`, not `error`: without a report TestFleet cannot tell, and a false "infrastructure error" hides real failures. This is why a [JUnit report](/suites/results-and-artifacts/#junit-xml) is strongly recommended.
- **Rule 5a** covers a Docker restart, which stops every suite with exit code 143 or 137 and would otherwise look like failing tests.

## Common errors

| Message, roughly                                                   | Cause                                             | What to do                                                              |
| ------------------------------------------------------------------ | ------------------------------------------------- | ----------------------------------------------------------------------- |
| pull access denied, unauthorized                                   | The registry needs credentials, or they are wrong | Add or fix the [registry](/guides/registries/); use **Test connection** |
| manifest unknown, not found                                        | The image or tag does not exist                   | Check the reference; was the image pushed?                              |
| no matching manifest for linux/arm64                               | The image was built for another platform          | Build a [multi-platform image](/operate/arm/)                           |
| pull timed out                                                     | The pull took longer than 10 minutes              | Check the network; raise `PULL_TIMEOUT_SECONDS` for very large images   |
| memory limit exceeded                                              | The suite needed more memory than its limit       | Raise the test definition's memory, or run fewer workers                |
| The suite exited with code N, but its JUnit report has no failures | Rule 9 above                                      | Look at the end of the log for the crash                                |
| Docker was interrupted                                             | The Docker daemon restarted during the run        | Run it again                                                            |

No run is ever retried automatically. A flaky suite should be visible as flaky, not hidden behind a second attempt.

## Pinning

**Pin** a finished run to exempt it from retention: its artifacts and log stay until you unpin it. Useful for runs you link from a bug report.

## After a TestFleet restart

Suites run in their own containers, independent of the TestFleet process. When TestFleet restarts (an upgrade, a crash), it finds its containers again: a still-running suite is reattached and its log continues without gaps or duplicates; a suite that finished meanwhile is collected and finalized as usual. Runs that were still `queued` simply wait for the dispatcher.
