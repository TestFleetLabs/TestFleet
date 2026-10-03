---
title: Results and artifacts
description: How TestFleet reads JUnit XML, collects artifacts, limits their size, and expires them.
---

When a suite's container has exited, TestFleet copies `/TestFleet/artifacts/` out of it, reads the JUnit reports in it, and keeps the files with the run. This also happens after a timeout or a cancellation: partial screenshots and traces are often the most useful evidence.

## JUnit XML

TestFleet reads:

- `/TestFleet/artifacts/junit.xml`, if present
- every `*.xml` file directly in `/TestFleet/artifacts/junit/`, for suites that write one report per shard or worker

Practically every test runner can write JUnit XML: Playwright and Jest (`junit` reporter, `jest-junit`), Cypress (`mocha-junit-reporter`), pytest (`--junitxml`), .NET (`JunitXml.TestLogger`), Go (`go-junit-report`), Maven Surefire, and Gradle.

Each `<testcase>` becomes a test result:

| In the report | Result                          |
| ------------- | ------------------------------- |
| `<failure>`   | failed                          |
| `<error>`     | error (shown apart from failed) |
| `<skipped>`   | skipped                         |
| none of these | passed                          |

Root `<testsuites>`, a single `<testsuite>`, and nested suites (as Jest writes them) are all understood. A test's suite is its innermost enclosing suite.

The run page lists failed tests first, with their message and stack trace, and the rest behind "Show all". Run lists show the counts at a glance.

:::note[Safe parsing]
Reports are parsed without external entities; a report with a `<!DOCTYPE` is refused, and so is a file over 50 MiB. A file that cannot be parsed adds a warning to the run and is skipped; the others still count.
:::

### Why JUnit matters for the status

Without a report, TestFleet knows only the exit code. With one, it can tell a test failure from a crash:

- exit code `0`, but the report has failures → `failed` (the suite swallowed its exit code)
- exit code non-zero, and the report has failures → `failed`
- exit code non-zero, but the report has no failures → `error` (the runner, a reporter, or a setup step crashed outside the tests)
- exit code non-zero and no report → `failed`

See the full [decision table](/guides/runs/#how-the-final-status-is-decided).

## Artifacts

Every other file in `/TestFleet/artifacts/` is kept as an artifact, directory structure included. JUnit files stay available as artifacts too.

On the run page:

- images (`png`, `jpg`, `gif`, `webp`) are shown as thumbnails, videos (`webm`, `mp4`) play inline
- an HTML file opens in a new tab; a directory with an `index.html`, such as `playwright-report/`, gets an **Open report** link
- everything else downloads

HTML reports run in a **sandbox**: their scripts run, but in an isolated origin without access to TestFleet's pages or cookies. Reports that need `localStorage` may not work fully.

### Size limit

A run may keep up to **500 MiB** of artifacts (`ARTIFACT_LIMIT_MB`). The download from the container stops as soon as it passes the limit, so a suite that writes gigabytes of video cannot fill the disk. Over the limit, TestFleet discards the files, keeps only the JUnit reports, and records the warning "Artifacts exceeded 500 MiB; only the JUnit files were kept".

To stay under it, record videos and traces only for failures (`retain-on-failure` in Playwright).

### Unsafe entries

The archive from a container is untrusted. Symbolic links, hard links, devices, and paths that are absolute or contain `..` are skipped, with a warning on the run.

## Retention

TestFleet removes old artifacts and logs every hour, so the disk does not fill up. Runs and their test results are kept forever.

| What      | Kept for                       | Setting                   |
| --------- | ------------------------------ | ------------------------- |
| Artifacts | 30 days after the run finished | `ARTIFACT_RETENTION_DAYS` |
| Logs      | 90 days after the run finished | `LOG_RETENTION_DAYS`      |

Exceptions, kept regardless of age:

- **Pinned runs.** Use **Pin** on a finished run to keep its artifacts and log, for example as evidence for a bug report. Unpin it, and the next cleanup applies the normal rules.
- **The latest problem run** per test definition and environment: the newest run that ended `failed`, `timeout`, or `error` keeps its artifacts until a newer problem run replaces it.

An expired run says so ("Artifacts expired on …"); over the API its log and artifacts answer `410 Gone`.

Artifacts live in the `testfleet_artifacts` Docker volume, or a host directory of your choice; see [Upgrade, back up, maintain](/operate/maintenance/#artifacts-on-a-host-directory).
