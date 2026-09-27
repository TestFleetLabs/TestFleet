# TestFleet — Milestone 6: Results and Artifacts

## 1. Purpose

Milestone 6 keeps what a suite leaves behind: its JUnit results become structured test results, its files (screenshots, videos, traces, reports) become downloadable artifacts, and both survive the container. Retention keeps the disk from filling up.

```text
container exited
  ↓
RunExecution: copy /TestFleet/artifacts (size limit, safe extraction)
  ↓            parse JUnit → decision table rules 6, 8, 9
Result (status, artifacts, test results)
  ↓
Runs.Recorder: final status + artifacts + test_results in one transaction
  ↓
Run page: tests, artifacts, downloads
  ↓
CleanupWorker: retention
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines test results (section 10), artifacts (section 11), the container contract (section 12), the decision table (section 24), and the artifact lifecycle with retention (section 46). The execution spike already copies and extracts the artifacts directory ([execution-spike-spec.md](execution-spike-spec.md), section 7); Milestone 3 passes `artifact_path: nil`, so nothing is collected yet. This document records what the main spec leaves open, and where the implementation deviates.

---

## 2. Scope

### In scope

- Collecting artifacts per run into local storage, with the per-run size limit and safe extraction
- Parsing JUnit XML, and the JUnit rules of the decision table
- The `artifacts` and `test_results` tables, and test counts and warnings on runs
- Run page: tests panel, artifacts panel with previews, downloads; test counts in run lists
- Retention of artifacts and logs, with the "latest failure" exception and pinned runs

### Out of scope

| What | Milestone |
|------|-----------|
| Object storage (S3, MinIO) | later; the storage module leaves room for it |
| Per-test history and flakiness views | later; the index for them is created now |
| Downloading all artifacts as one archive | later |
| Removing artifact directories without a run row | 7 (orphans) |
| `GET /api/runs/:id/artifacts` | with the API |

---

## 3. Data Model

### `artifacts`

| Column | Type | Notes |
|--------|------|-------|
| `run_id` | FK `runs`, `on_delete: :delete_all` | |
| `name` | text | Path relative to the artifacts directory, e.g. `screenshots/login.png` |
| `content_type` | text | From the extension (`MIME.from_path/1`) |
| `size_bytes` | bigint | |
| `storage_backend` | text | `local` |
| `storage_key` | text | `<run_id>/<name>` |
| `inserted_at` | `utc_datetime` | |

Unique index on `(run_id, name)`. No `updated_at`: artifacts never change.

### `test_results`

| Column | Type | Notes |
|--------|------|-------|
| `run_id` | FK `runs`, `on_delete: :delete_all` | |
| `test_definition_id` | FK `test_definitions` | Copied from the run, for the identity below |
| `suite`, `classname`, `name` | text | `suite` is the enclosing `<testsuite name>`; `classname` may be empty |
| `status` | text | `passed`, `failed`, `error`, `skipped` |
| `duration_ms` | integer, nullable | From `time` (seconds) |
| `failure_message` | text, nullable | The `message` attribute of `<failure>` / `<error>` |
| `failure_details` | text, nullable | The element's text (stack trace), cut at 64 KiB |
| `file` | text | The JUnit file it came from, e.g. `junit/shard-2.xml` |
| `inserted_at` | `utc_datetime` | |

- Index on `(test_definition_id, suite, classname, name)`: a test's identity across runs (main spec section 10), for per-test history later.
- Index on `(run_id, status)`: the run page lists failed tests first.
- **Deviation:** no `updated_at` (rows never change), and `test_definition_id` and `file` are added.

### New columns on `runs`

| Column | Type | Purpose |
|--------|------|---------|
| `tests_passed`, `tests_failed`, `tests_skipped` | integer, nullable | Counts from JUnit; `tests_failed` includes errors. `nil` when the run had no JUnit. Run lists show them without counting rows. |
| `warnings` | text array, default `[]` | Collection problems, e.g. the size limit or an unreadable JUnit file (main spec section 12: "records a warning on the run") |
| `pinned` | boolean, default false | Exempt from retention |
| `artifacts_expired_at`, `logs_expired_at` | `utc_datetime_usec`, nullable | Set by retention, so the page says "expired" instead of showing nothing |

---

## 4. Collecting Artifacts

### Where

`config :testfleet, TestFleet.Artifacts, root: ...` (`ARTIFACTS_DIR` at runtime, default `/var/lib/TestFleet/artifacts`, the mounted volume of the containerized deployment). Dev uses `tmp/artifacts`, test `tmp/test_artifacts`.

A run's files go to `<root>/<run_id>/`. `Runs.build_request/1` sets `artifact_path` to it, and the startup recovery passes it to `Execution.attach/2`.

`TestFleet.Artifacts.Storage` is the only module that turns a storage key into a file path. It has one backend, `Local`. Object storage later adds a backend and an upload step after collection; the execution model stays the same.

### Size limit

`config :testfleet, TestFleet.Artifacts, max_bytes: 500 * 1024 * 1024` (`ARTIFACT_LIMIT_MB`).

- The archive is downloaded with a byte cap: the download stops as soon as it passes the limit, so a suite that writes 20 GB of video cannot fill TestFleet's disk first. The limit is measured on the tar stream, which adds about 512 bytes per file.
- **Over the limit:** the partial download is deleted. TestFleet then downloads only `/TestFleet/artifacts/junit.xml` and `/TestFleet/artifacts/junit/`, each with the same cap, keeps those, and records the warning "Artifacts exceeded 500 MiB; only the JUnit files were kept" (main spec section 12).

### Safe extraction

A tar stream from a container is untrusted input. Before extracting, TestFleet reads the tar's table and extracts only regular files and directories:

- symbolic links, hard links, devices, and FIFOs are skipped
- names that are absolute or contain `..` are skipped
- skipped entries are counted in one warning ("3 entries were skipped: links or unsafe paths")

This closes the gap noted in the spike (spike spec section 14: "Artifact extraction does not yet guard against symlinks").

---

## 5. JUnit

### Files

Every `*.xml` file directly under `junit/`, plus `junit.xml`, in the collected artifacts (main spec section 10). They stay artifacts too.

### Parsing

`TestFleet.Results.JUnit.parse(xml)` is a pure function: no database, so `RunExecution` can call it. It returns the test cases, or an error.

- Accepts `<testsuites>` at the root, a single `<testsuite>`, and nested suites (Jest). `suite` is the innermost enclosing suite's `name`.
- `<testcase>` with `<failure>` → `failed`, `<error>` → `error`, `<skipped>` → `skipped`, otherwise `passed`. `time` is seconds, possibly fractional.
- `<system-out>`, `<system-err>`, and `<properties>` are ignored.
- **Safety:** parsed with OTP's `:xmerl_sax_parser` without external entities. A document with a `<!DOCTYPE` is rejected, which rules out entity expansion attacks. A file over 50 MiB is not parsed.
- A file that cannot be parsed adds a warning ("junit/shard-2.xml could not be parsed: …") and is ignored. If no file could be parsed, the run counts as having no JUnit.

### Decision table

`Execution.Status.decide/1` gets the JUnit summary as a fact (`junit: nil | %{failed: n}`, where `failed` counts failures and errors), and implements the remaining rules of main spec section 24:

| # | Condition | Status |
|---|-----------|--------|
| 6 | Exit code 0 and JUnit reports failures or errors | `failed` |
| 8 | Exit code non-zero and JUnit reports at least one failure | `failed` |
| 9 | Exit code non-zero, JUnit present, no failures | `error`: "The suite exited with code N, but its JUnit report has no failures" |
| 10 | Exit code non-zero and no JUnit | `failed` (as before) |

Rules 1–5 still come first: a cancelled, timed-out, or OOM-killed run keeps its status whatever the JUnit says. Its results and artifacts are still stored; partial results are often the most useful.

### Why in the execution process

The decision table lives in one place, `Status`, and needs the JUnit facts. Parsing where the files are extracted keeps the final status in the `Result`, as for every other rule, and keeps the recorder a writer only. `TestFleet.Results.JUnit` touches no database and no configuration, so this does not break the execution isolation.

### Events

`Result` gains `test_results` and `warnings`. The main spec's `{:run_test_result, result}` event is dropped: JUnit exists only after the suite finished, so the results arrive together with `{:run_finished, run}`, whose counts tell the page to load them. **Deviation**, main spec section 22 is updated.

---

## 6. Persisting

`Runs.finish/2` (called by the recorder with the `Result`) writes, in one transaction:

1. The final status, as before, plus the test counts and warnings.
2. The `artifacts` rows (`insert_all`, `on_conflict: :nothing` for a repeated finish after a reattach).
3. The `test_results` rows, in chunks of 1,000.

Then it broadcasts `{:run_finished, run}`. A run is never visible as finished without its results. The guarded transition (Milestone 3) still decides: a late second finish changes nothing, and inserts nothing.

---

## 7. UI

### Run page

**Tests panel** (only when the run has JUnit):

- The counts: "42 passed · 2 failed · 1 skipped", and the total test time.
- Failed and errored tests first, each with suite, class, name, duration, and the failure message. The details (stack trace) open in a `<details>` element, monospace.
- The other tests collapsed behind "Show all 45 tests", loaded on demand (a suite can have thousands).
- `failed` and `error` differ in colour and icon, like the run statuses.

**Artifacts panel:**

- The files as a tree by directory, with sizes and the total.
- Images (`png`, `jpg`, `gif`, `webp`) as thumbnails that open full size. Videos (`webm`, `mp4`) play inline on click.
- An HTML file opens in a new tab ("Open report"). A directory with an `index.html` gets that link on the directory.
- The warnings of the run, above the list.
- "Artifacts expired on …" when retention removed them; the tests stay.
- A run without artifacts shows nothing, not an empty panel.

**Pin:** a "Pin" toggle in the header exempts the run from retention.

### Downloads

`GET /runs/:id/artifacts/*name` serves one artifact.

- The name is looked up in `artifacts` for that run. Only stored names are served; the request never builds a file path. Unknown → 404.
- `Content-Type` from the row, `X-Content-Type-Options: nosniff`.
- Images, videos, PDF, and text are served inline; other types as attachments.
- **HTML is served with `Content-Security-Policy: sandbox allow-scripts allow-popups allow-forms`** (no `allow-same-origin`). A report is someone else's HTML: with this header it runs in an opaque origin and cannot reach TestFleet's cookies or pages, but scripts still run. Relative links within a report work, because the route keeps the directory structure.
  - **Known limit:** a report that needs `localStorage` fails in an opaque origin. A separate artifacts origin (`ARTIFACTS_ORIGIN`) is the complete fix, later.
- Range requests are supported, so videos can seek.

### Run lists

Rows in the runs list, the dashboard, and the project and test definition pages show the counts compactly ("42 ✓ 2 ✗") when the run has JUnit.

---

## 8. Retention

`TestFleet.Artifacts.CleanupWorker`, an Oban cron job once per hour, in the `cleanup` queue.

```elixir
config :testfleet, TestFleet.Retention,
  artifacts_days: 30,   # ARTIFACT_RETENTION_DAYS
  logs_days: 90         # LOG_RETENTION_DAYS
```

- A run's artifacts expire `artifacts_days` after `finished_at`, its logs `logs_days` after. Runs and test results are kept (main spec section 46).
- **Exceptions:**
  - pinned runs
  - the latest run per test definition and environment whose status is `failed`, `timeout`, or `error`. **Deviation:** the main spec says "most recent failed run"; timeouts and errors are just as much worth investigating.
- **Expiring artifacts:** delete the run's directory, then its `artifacts` rows, and set `artifacts_expired_at`. The directory goes first: a crash in between leaves rows without files, which the page shows as missing, never files nobody can find.
- **Expiring logs:** delete the run's `run_logs` rows in batches of 10,000, then set `logs_expired_at`.
- **Batches:** at most 100 runs per job. A backlog shrinks over the next runs of the job, without long transactions.
- Unpinning a run whose age is past the limit lets the next job expire it.

---

## 9. Fixture

New modes of the fixture suite:

- `junit_pass`: writes `junit.xml` with passing and skipped tests, exits 0
- `junit_fail`: writes a failure and an error, exits 1
- `junit_swallow`: writes a failure, exits 0 (rule 6)
- `junit_crash`: writes only passing tests, exits 1 (rule 9)
- `junit_shards`: writes `junit/shard-1.xml` and `junit/shard-2.xml`
- `big_artifacts`: writes a JUnit file and `SPIKE_ARTIFACT_MB` MiB of data (default 5)
- `unsafe_artifacts`: writes a symlink to `/etc/passwd` next to a normal file

The image must be rebuilt and pushed afterwards (spike spec section 9).

---

## 10. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Collection: artifacts root and storage, size limit with the JUnit fallback, safe extraction, JUnit parser, decision table rules 6, 8, 9, `Result` fields, recovery passes `artifact_path`. | – |
| B | Persisting: `artifacts` and `test_results` tables, the new `runs` columns, `Runs.finish/2` in one transaction. | A |
| C | UI: tests panel, artifacts panel with previews, the download route with its headers, counts in run lists. | B |
| D | Retention: `CleanupWorker`, pinning, expired states. | B |

Each slice passes `mix precommit` on its own.

**Status (2026-09-27):** specified; not started.

---

## 11. Tests

- **`JUnit.parse/1`:** each root form, nested suites, each status, durations, missing `classname`, a `DOCTYPE` rejected, invalid XML, details cut at 64 KiB.
- **`Status.decide/1`:** rules 6, 8, 9, 10, and rules 1–5 winning over JUnit.
- **Extraction:** links and unsafe names skipped with a warning; regular files and directories kept.
- **Collection** (Docker): each fixture mode; the size limit keeps only JUnit, with the warning; shards merged; results collected after a timeout and a cancel.
- **`Runs.finish/2`:** rows and counts written in one transaction; a repeated finish inserts nothing.
- **Downloads:** inline and attachment types, the sandbox header on HTML, nosniff, unknown names 404, names with `..` 404, range requests.
- **Retention:** expiry by age, pinned runs kept, the latest failure per test definition and environment kept, batches, expired states on the page.
- **LiveViews:** tests panel (failed first, show all), artifacts panel (tree, previews, expired, warnings), pin toggle, counts in rows.
- **End to end** (Docker): a `junit_fail` run through the dispatcher ends `failed` with its test results and artifacts stored and downloadable.

---

## 12. Done

Milestone 6 is done when all slices pass `mix precommit` and the Docker tests, and a manual walkthrough works:

1. Run `junit_fail` and see the failed test with its message and stack trace, and the counts in the runs list.
2. Run `junit_swallow` (exit 0) and see `failed`; run `junit_crash` and see `error` with its explanation.
3. Open a screenshot and the HTML report from the artifacts panel.
4. Run `big_artifacts` over a small limit and see the warning and the kept JUnit results.
5. Set a retention of 0 days, run the cleanup, and see "expired" on an old passing run, while the latest failing run and a pinned run keep their artifacts.
