---
title: The container contract
description: Everything a test suite image needs to do to run in TestFleet.
---

This page is the complete contract between TestFleet and a test suite image. If your image follows it, TestFleet can run it, whatever framework is inside.

## Input: environment variables only

The suite gets its configuration exclusively through environment variables:

- the variables of the [environment](/guides/environments/) the run targets, such as `BASE_URL` or a test user's password
- three reserved variables that TestFleet sets on every run:

| Variable                  | Example                | Meaning                              |
| ------------------------- | ---------------------- | ------------------------------------ |
| `TestFleet_RUN_ID`        | `1842`                 | The run's id, as in `/runs/1842`     |
| `TestFleet_ENVIRONMENT`   | `production`           | The environment's name               |
| `TestFleet_ARTIFACTS_DIR` | `/TestFleet/artifacts` | Where to write results and artifacts |

The `TestFleet_` prefix is reserved: environment variables starting with it (in any case) are refused when you save them.

The image must not need interactive input, mounted files, or build-time secrets. Everything that differs between environments comes from variables. A file a suite needs, such as a client certificate, can be passed as a base64-encoded secret variable and decoded at start.

## Execution

- The suite starts through the image's `ENTRYPOINT` and `CMD`, or through the test definition's **command** if one is set. Using the image's own entrypoint is recommended: the image knows how to run its suite.
- A command is a list of arguments, not a shell line. TestFleet never parses shell syntax; to use a shell, configure `sh`, `-c`, `<script>` as three arguments.
- The suite must finish within the test definition's timeout (30 minutes by default).
- On `SIGTERM` the suite should exit promptly. When a run is cancelled or times out, Docker sends `SIGTERM`, waits a grace period of 30 seconds, then sends `SIGKILL`.

:::tip[Exit on SIGTERM]
Shell scripts as `ENTRYPOINT` often ignore `SIGTERM`, because the shell does not forward it to the test runner. Use `exec` for the last command (`exec npx playwright test`), or the exec form of `CMD`, so the runner receives the signal itself.
:::

## Output

| What                                              | How                                                                                                           |
| ------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Result**                                        | The exit code: `0` means all tests passed, anything else means failure                                        |
| **Logs**                                          | Written to stdout and stderr; TestFleet stores and streams them                                               |
| **Test results** (optional, strongly recommended) | JUnit XML at `/TestFleet/artifacts/junit.xml`, or one file per shard under `/TestFleet/artifacts/junit/*.xml` |
| **Artifacts** (optional)                          | Any other files under `/TestFleet/artifacts/`: screenshots, videos, traces, HTML reports                      |

```text
/TestFleet/artifacts/
├── junit.xml
├── screenshot-login.png
├── screenshot-checkout.png
└── playwright-report/
    └── index.html
```

The exit code and the JUnit report are combined to decide the final status. For example, a suite that exits `0` while its JUnit report contains failures still ends `failed`. See [how the final status is decided](/guides/runs/#how-the-final-status-is-decided).

## The artifacts directory

The directory `/TestFleet/artifacts` must exist and be **writable by the user the image runs as**. Create it in the Dockerfile with the right owner:

```dockerfile
RUN mkdir -p /TestFleet/artifacts && chown -R 10001:10001 /TestFleet
USER 10001
```

A missing or empty directory is not an error: the run simply has no artifacts and no test results. After the container exits, TestFleet copies the directory out of the stopped container, so nothing has to be uploaded by the suite.

Artifacts are limited per run (500 MiB by default). Over the limit, TestFleet keeps only the JUnit files and records a warning on the run. See [Results and artifacts](/suites/results-and-artifacts/).

## What the container may and may not do

Test containers run hardened. Design the image so it does not need more:

- no Linux capabilities (all are dropped) and `no-new-privileges`, so no `sudo`, no `ping` with raw sockets, no binding to ports below 1024
- no privileged mode and no host mounts
- shared memory (`/dev/shm`) of 2 GiB by default, enough for Chromium-based browsers
- the CPU and memory limits of its test definition; exceeding the memory limit ends the run as `error`
- its own network, `TestFleet-runs`, with outbound access to what it tests, but no access to TestFleet's database or the Docker socket

## Platforms

TestFleet runs the image on its own host. If that host is `arm64` (for example a [Raspberry Pi](/operate/arm/)), the image must exist for `linux/arm64`; build it for both platforms with `docker buildx build --platform linux/amd64,linux/arm64`.

## Checklist

- [ ] The suite starts without arguments (or with the configured command)
- [ ] It reads every target address and credential from environment variables
- [ ] It exits `0` only when all tests passed
- [ ] It writes a JUnit report to `$TestFleet_ARTIFACTS_DIR/junit.xml`
- [ ] `/TestFleet/artifacts` exists and belongs to the image's user
- [ ] It stops on `SIGTERM`
- [ ] It is published to a registry TestFleet can pull from, for the host's platform
