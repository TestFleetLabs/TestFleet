---
title: Test definitions
description: Configure which image a suite runs, with which command, timeout, and resource limits.
---

A test definition says **what** to run. It belongs to a project; a project can have several, such as a quick smoke suite every 15 minutes and a full regression suite every night.

## Fields

| Field             | Default       | Notes                                                                         |
| ----------------- | ------------- | ----------------------------------------------------------------------------- |
| **Name**          | –             | Up to 100 characters                                                          |
| **Slug**          | from the name | Lowercase letters, digits, and dashes; names the suite in the [API](/ci/api/) |
| **Image**         | –             | A full image reference, such as `ghcr.io/acme/portal-e2e:1.4.2`               |
| **Command**       | empty         | One argument per line; empty runs the image's own `ENTRYPOINT`/`CMD`          |
| **Timeout**       | 30 minutes    | 1 minute to 24 hours                                                          |
| **CPUs**          | unlimited     | Fractions allowed, such as `1.5`                                              |
| **Memory**        | unlimited     | In MiB, at least 6                                                            |
| **Shared memory** | 2048 MiB      | Size of `/dev/shm`; browsers crash with Docker's default of 64 MiB            |
| **Enabled**       | yes           | Disabled definitions cannot be run, and their schedules skip                  |

## Image

Below the image field, the form shows which [registry](/guides/registries/) credentials a pull will use, or that the image will be pulled anonymously.

**Tags and digests.** Every run records the digest it actually used, so even a moving tag stays traceable. You choose how the image is referenced:

| Reference             | Pulled              | Good for                                                           |
| --------------------- | ------------------- | ------------------------------------------------------------------ |
| `portal-e2e:1.4.2`    | before every run    | Versioned suites, updated by the [pipeline](/ci/pipelines/)        |
| `portal-e2e:main`     | before every run    | "Always test the latest suite"; the next run picks up a pushed tag |
| `portal-e2e@sha256:…` | only if not present | Exact reproducibility                                              |

A pull has its own timeout (10 minutes, `PULL_TIMEOUT_SECONDS`), separate from the run's. A pull that fails or times out ends the run as `error`. When several runs need the same image at once, TestFleet pulls it once.

Changing the image affects runs created **from then on**. Queued and running runs keep the image they were created with.

## Command

A command is a list of arguments, entered one per line. There is no shell: `$VARIABLES`, pipes, and `&&` are passed through literally. To use them, start a shell explicitly:

```text
sh
-c
npx playwright test --project="$BROWSER"
```

Leave the command empty when the image's `CMD` already runs the suite. That keeps the knowledge of how to run the suite in the suite's repository.

## Limits

**Timeout.** When it expires, TestFleet stops the container (`SIGTERM`, then `SIGKILL` after 30 seconds) and the run ends `timeout`. Artifacts written so far are still collected. The deadline counts from the moment the container started; the image pull does not count, and neither does a TestFleet restart: time spent down still counts against the deadline.

**Memory.** A suite that exceeds its memory limit is killed by Docker and the run ends `error` with "memory limit exceeded", not `failed`: running out of memory is not a test failure. Browser suites typically need 2–4 GiB.

**CPUs.** Unlimited by default. On a shared host, a limit keeps one suite from slowing every other run down.

Together with the [concurrency limits](/guides/environments/#concurrency), these keep one suite from overloading the host or the system it tests.

## Disabling

Disable a test definition to pause it without deleting anything: **Run now** is unavailable, schedules record a skipped run instead of starting one, and the API answers `409`. Enable it again, and schedules continue at their next slot.
