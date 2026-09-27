# TestFleet — Milestone 4: Live Output

## 1. Purpose

Milestone 4 makes a run's output visible: while the suite runs, its log lines appear on the run page within a fraction of a second, and afterwards the complete log stays available from PostgreSQL.

```text
Docker log stream
  ↓
RunExecution: split into lines → mask secrets → number → batch (100 ms / 500 lines)
  ↓
Runs.Recorder: insert_all into run_logs (up to the log limit) → broadcast on run:<id>
  ↓
Run page LiveView
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines the log table (section 9), streaming, masking, batching, and the log limit (section 21), the PubSub event (section 22), the run page (section 23), reattaching (section 32), and the logging architecture (section 45). This document records what the main spec leaves open, and where the implementation deviates.

The execution spike already built most of the Docker side: the log stream, frame decoding, line splitting (`LineBuffer`), sequence numbers, and resuming after reattaching with `since`. Milestone 3 ignores the `{:output, lines}` events. This milestone builds on those parts.

---

## 2. Scope

### In scope

- Secret masking in `RunExecution`, before any event leaves the process
- Batching in `RunExecution`: one `{:output, lines}` event per 100 ms, 500 lines, or 1 MiB
- The `run_logs` table, and persisting batches through `Runs.Recorder`
- The per-run log limit
- `{:run_output, lines}` on `run:<id>`
- Masking, and resuming logs without gaps or duplicates, after a reattach (Milestone 3's startup recovery)
- The log panel on the run page: history, live tail, auto-follow, stderr, masked values
- Downloading the full log as a text file

### Out of scope

| What | Milestone |
|------|-----------|
| Log retention (90 days) | 6 (retention) / 7 (cleanup) |
| Partitioning `run_logs` | when it grows |
| Rendering ANSI colours (they are stripped for display) | later |
| Search and filters in the log | later |
| Masking encoded forms of a secret (base64, URL encoding) | later |

---

## 3. Data Model

### `run_logs`

One row per line (main spec section 9):

| Column | Type | Notes |
|--------|------|-------|
| `id` | bigserial | |
| `run_id` | bigint, FK `runs`, `on_delete: :delete_all` | Logs belong to their run; retention deletes both. |
| `sequence` | integer | 1, 2, 3, … per run, assigned by `RunExecution` |
| `stream` | text | `stdout` or `stderr` (`Ecto.Enum`) |
| `content` | text | masked; without the trailing newline |
| `timestamp` | bigint | Docker's timestamp in nanoseconds, nullable |

- Unique index on `(run_id, sequence)`. It serves loading the log in order and the tail, and it makes a repeated insert after a reattach harmless (`on_conflict: :nothing`).
- No `inserted_at`/`updated_at`: rows are never updated, and `timestamp` holds the time that matters. This keeps the largest table narrow.

### New columns on `runs`

| Column | Type | Purpose |
|--------|------|---------|
| `last_log_sequence` | integer, default 0 | The highest sequence received. A reattaching process continues from it. |
| `log_bytes` | bigint, default 0 | Bytes of `content` stored so far, for the log limit. |
| `log_truncated` | boolean, default false | The log limit was reached; later lines were streamed but not stored. |

`last_log_timestamp` (created in Milestone 3) is written from now on.

---

## 4. Masking

`TestFleet.Execution.Masker` replaces every occurrence of a secret value with `[MASKED]` (main spec section 21).

- **Where:** in `RunExecution`, on each complete line, before numbering and batching. No event, subscriber, or handler ever sees an unmasked line. `Execution.run/1` and the spike tests are masked too.
- **What:** the values of the run's secret variables (`Request.secret_values`). A multi-line secret (for example a PEM key) is masked line by line: each of its lines is its own pattern, if it is at least 6 characters long (the minimum length of a secret, Milestone 2).
- **How:** one compiled pattern (`:binary.compile_pattern/1`) per run, built once. When several secrets match at the same position, the longest wins, so a secret that contains another is masked completely.
- **Known limits** (documented, not solved):
  - A secret split across two lines, or by `LineBuffer`'s 1 MB overflow split, is not masked.
  - A secret interrupted by ANSI escape codes, or encoded (base64, URL encoding), is not masked.
  - Non-secret variables are never masked.

### After a reattach

An attaching process has no request, so it does not know the secret values. The container does: they are in its environment.

- On create, `RunExecution` stores the **keys** of the secret variables as the label `TestFleet.secret_keys` (comma-separated). Keys are not secret.
- On attach, it reads `Config.Env` from the inspected container and masks the values of those keys.

This follows the Milestone 3 pattern for `TestFleet.timeout_seconds`: everything an attaching process needs is on the container, and masking never depends on variables that may have changed since the run started.

---

## 5. Batching

`RunExecution` collects masked, numbered lines and emits `{:output, lines}` when the first of these happens:

- 100 ms have passed since the first line of the batch arrived (a timer per batch, not a periodic tick)
- 500 lines are pending
- 1 MiB of content is pending

The byte limit is an addition to the main spec. Lines can be up to 1 MB long (`LineBuffer`), and 500 of them would make one message of 500 MB.

The pending batch is flushed before `{:finished, result}`. All stored lines are therefore in PostgreSQL before the run is final.

Batching lives in the execution process, as the main spec says: the handler is called once per batch, and the Docker stream is not read while a batch is being written. A slow database slows down reading the log, not the suite; Docker keeps the output.

---

## 6. Persisting

`Runs.Recorder` handles `{:output, lines}` with `Runs.append_log(run_id, lines)`:

1. Strip NUL bytes (`\0` → `�`). PostgreSQL `text` cannot hold them, and one NUL would otherwise crash the run's process.
2. In one transaction:
   - Update the run: `last_log_sequence` and `last_log_timestamp` of the batch's last line, and `log_bytes + batch bytes`.
   - `insert_all` the lines that fit under the log limit (`on_conflict: :nothing`).
   - If a line does not fit: store none of the later lines, and set `log_truncated = true`.
3. Broadcast `{:run_output, lines}` on `run:<id>`, with **all** lines of the batch, stored or not (main spec section 21: "keeps streaming only the tail to connected clients").

After the limit is reached, a batch only updates the run (sequence, timestamp) and is broadcast. The check reads `log_bytes` and `log_truncated` from the update's `RETURNING`, so no extra query is needed.

**Deviation:** the main spec stores "a single truncation marker". Here the marker is `runs.log_truncated`, and the page and the download render it as a final line. `run_logs` then only holds container output.

**The log limit:**

```elixir
config :testfleet, TestFleet.Runs, max_log_bytes: 50 * 1024 * 1024   # RUN_LOG_LIMIT_MB at runtime
```

It counts the bytes of `content`, not of rows or indexes.

**Broadcast lines** are maps `%{sequence, stream, content, timestamp}`, the same fields as the rows. `{:run_output, _}` is only broadcast on `run:<id>`, never on `runs` (Milestone 3, section 4).

---

## 7. Reattaching

Milestone 3's startup recovery attaches with `last_log_timestamp`. It now also passes `next_sequence: run.last_log_sequence + 1`.

- `RunExecution` resumes with `since = last_log_timestamp` and discards lines whose timestamp is not newer (built in the spike).
- Lines that were buffered in memory when TestFleet stopped were never persisted, so `last_log_timestamp` does not cover them. They are read again from Docker.
- Lines that were persisted but whose `last_log_timestamp` update was lost cannot happen: both are written in one transaction.
- Two lines with the same nanosecond timestamp, one stored and one not, lose the second. Docker's timestamps make this practically impossible.

---

## 8. UI

### Log panel on the run page

- **History:** on mount, the last 1,000 stored lines are loaded (`Runs.list_log_tail(run, 1000)`). If there are earlier lines, a note at the top says so and links to the download.
- **Live tail:** the page subscribes to `run:<id>` **before** loading the history. A batch that overlaps the history does not duplicate lines: each line's DOM id is `log-<sequence>`, and a stream insert with an existing id updates the line in place.
- **Bounded DOM:** the lines are a LiveView stream with `limit: -2000`. A chatty suite cannot grow the page without bound.
- **Follow:** a colocated hook keeps the panel scrolled to the bottom while the user is at the bottom. Scrolling up pauses following; a "Jump to latest" button resumes it.
- **Presentation:**
  - monospace, the line number (`sequence`) in a muted gutter, and long lines wrap
  - stderr lines are tinted
  - `[MASKED]` is shown as a small badge, so masked values are easy to recognise
  - ANSI escape sequences are stripped for display (stored unchanged)
- **States:**
  - queued or preparing without output: "Waiting for output…"
  - running: a subtle live indicator in the panel header
  - finished without output: "The suite produced no output."
  - `log_truncated`: a final line "Log limit of 50 MB reached. Later output was shown live but not stored."
- **Reconnect:** LiveView mounts again and reloads the history from PostgreSQL (main spec section 23).

### Download

`GET /runs/:id/log` returns the stored log as `text/plain; charset=utf-8`, with `Content-Disposition: attachment; filename="run-<id>.log"`.

- One line per row, in sequence order. It is streamed from PostgreSQL in chunks (`Repo.stream` in a transaction), so a 50 MB log never sits in memory.
- A truncated log ends with the truncation line.
- The content is already masked. Like everything else, the endpoint is not authenticated until authentication is built.

---

## 9. Fixture

The fixture suite gets a mode `secret` that prints the value of `SPIKE_SECRET` in the middle of a line, on its own, and twice on one line. After the change, the fixture image must be rebuilt and pushed to the spike registry ([execution-spike-spec.md](execution-spike-spec.md), section 9).

---

## 10. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Execution: `Masker`, masking in `RunExecution` (start and attach, `TestFleet.secret_keys` label), batching. Docker tests on the event stream. | – |
| B | Persisting: `run_logs`, the new `runs` columns, `Runs.append_log/2`, the log limit, `{:run_output, lines}`, the recorder, `next_sequence` in the recovery. End-to-end Docker tests. | A |
| C | UI: log panel with history, live tail, follow, and the states of section 8; download endpoint. | B |

Each slice passes `mix precommit` on its own.

**Status (2026-09-27):** specified; not started.

---

## 11. Tests

- **`Masker`:** single and multiple secrets, overlapping secrets (the longest wins), a secret twice on one line, multi-line secrets, short lines of a multi-line secret are skipped, no secrets.
- **`RunExecution`** (Docker):
  - the `secret` fixture mode: no event contains the value
  - a chatty suite: batches of at most 500 lines, sequences without gaps, all lines before `{:finished, _}`
  - attach: output after a reattach is masked, from the label and the container environment
- **`Runs.append_log/2`:** rows and run columns written; NUL bytes replaced; a repeated batch is ignored; the log limit truncates within a batch and later batches store nothing; broadcasts contain all lines.
- **Recovery** (Docker): after a restart during a ticking suite, the stored sequences have no gaps or duplicates.
- **End to end** (Docker): "Run now" with the `secret` mode stores masked lines; a chatty suite stores all 100,000 lines; a small log limit truncates.
- **LiveView:** history with the "earlier lines" note, live lines appended, stderr and `[MASKED]` presentation, empty and truncated states.
- **Download:** content in order, the truncation line, the headers.

---

## 12. Done

Milestone 4 is done when all slices pass `mix precommit` and the Docker tests, and a manual walkthrough works:

1. Run a ticking suite and watch the lines appear live on the run page.
2. Scroll up while it runs: following pauses; "Jump to latest" resumes it.
3. Run the `secret` mode and see `[MASKED]` on the page, in the download, and in the `run_logs` table.
4. Restart TestFleet during a ticking run: the log continues without gaps or duplicates.
5. Reload the page of a finished run and see the stored log.
