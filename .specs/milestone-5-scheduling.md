# TestFleet — Milestone 5: Scheduling

## 1. Purpose

Milestone 5 makes schedules run. Every minute, a tick finds the schedules that are due, creates a queued run for each, and moves the schedule to its next occurrence. From there the run takes the same path as "Run now".

```text
Oban cron, every minute
  ↓
Schedules.TickWorker → Schedules.tick(now)
  ↓
due schedules (enabled, next_run_at <= now)
  ↓
Runs.create_scheduled(schedule, scheduled_for)   overlap policy
  ↓
Run (queued, trigger = schedule)
  ↓
Execution.Dispatcher → RunExecution
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines schedules (section 6), the tick (section 28), the single pipeline (section 29), and missed schedule alerts (section 48). Milestone 2 built schedules as data, including `next_run_at` with the DST rules ([milestone-2-test-configuration.md](milestone-2-test-configuration.md), section 10). This document records what the main spec leaves open.

---

## 2. Scope

### In scope

- `Schedules.TickWorker` on Oban's cron plugin, and `Schedules.tick/1`
- `Runs.create_scheduled/2` with the overlap policies `skip`, `queue`, and `allow`
- Coalescing missed slots, and never creating a slot twice
- Recording each tick's outcome on the schedule, so a skipped run is visible
- The dispatcher waiting for a schedule's previous run under `queue`
- UI: the last outcome on schedule rows, the schedule on the run page, overdue schedules on the dashboard

### Out of scope

| What | Milestone |
|------|-----------|
| Alerts for missed schedules, and a dead man's switch ping | 8 |
| A schedule detail page with its run history | later |
| "Run now" for a schedule | later (the test definition page already has it) |
| API-triggered runs (`trigger = api`) | with the API |

---

## 3. Data Model

`runs.schedule_id` and `runs.scheduled_for` and the unique index on `(schedule_id, scheduled_for)` exist since Milestone 3.

New columns on `schedules`:

| Column | Type | Purpose |
|--------|------|---------|
| `last_tick_at` | `utc_datetime`, nullable | The slot (`scheduled_for`) the schedule last fired for |
| `last_tick_outcome` | text, nullable (`Ecto.Enum`) | `created`, `skipped_overlap`, or `skipped_disabled` |
| `last_run_id` | FK `runs`, nullable, `on_delete: :nilify_all` | The run created by the last tick that created one. A skip keeps it, so a skipped row can still point to the run that blocked it. |

The tick writes them with a direct update, so `schedules.updated_at` keeps meaning "configuration changed".

---

## 4. The Tick

**The worker.** `TestFleet.Schedules.TickWorker` is an Oban worker in the `schedules` queue with `max_attempts: 1` (main spec section 28), started by `Oban.Plugins.Cron` every minute. It calls `Schedules.tick(DateTime.utc_now())`. All logic is in `tick/1`, which tests call with a fixed `now`.

**A tick:**

1. Load the ids of the due schedules: `enabled` and `next_run_at <= now`, oldest first.
2. For each schedule, in its own transaction:
   1. Lock the schedule with `FOR UPDATE SKIP LOCKED` and check again that it is enabled and due. Skip it if it is locked or no longer due: another node or tick has it.
   2. Decide (section 5) and create the run, or skip.
   3. Advance `next_run_at` to the first occurrence **after `now`** (`Cron.next_run/3`), and record the outcome.
3. After each commit, broadcast `{:run_created, run}` for a created run. The dispatcher wakes up on it; broadcasting before the commit could wake it before the run is visible.

**Per-schedule transactions** instead of one for the whole tick (the main spec's sketch): one broken schedule cannot roll back or block the others, and a lock is held only for a moment.

**`scheduled_for`** is the slot the run was due for, the old `next_run_at`, not the time of the tick. `queued_at` is the time of the tick.

**Coalescing.** A schedule that missed slots (TestFleet was down) creates one run for its oldest missed slot, and then moves to the first occurrence after `now`. The number of missed slots is logged. A twice-daily schedule after three hours of downtime therefore creates one run.

**Never twice.** A slot is created at most once: the row lock covers concurrent ticks, and the unique index on `(schedule_id, scheduled_for)` covers everything else. The insert uses `on_conflict: :nothing`; a conflict counts as already created and still advances the schedule.

**Broken schedules.** A cron expression or time zone that no longer parses, or an expression that never matches again, cannot happen through the form. If it happens anyway (data changed by hand, a time zone removed from the database), the schedule is disabled and an error is logged. Leaving it enabled would fail every minute.

**Timing.** Oban's cron runs on the minute. A schedule for 06:00 creates its run within a few seconds after 06:00 while the queue is healthy. Because the tick picks up everything due, a late or skipped tick only delays runs; it never loses them.

---

## 5. Overlap Policy

A schedule's *own* unfinished runs are its runs (by `schedule_id`) in `queued`, `preparing`, or `running`. Manual runs of the same test definition and environment do not count: they are someone's deliberate choice.

| Policy | Unfinished own run exists | Result |
|--------|---------------------------|--------|
| `skip` (default) | yes | No run. Outcome `skipped_overlap`, logged. |
| `queue` | a `queued` one | No run. Outcome `skipped_overlap`: **at most one run waits.** |
| `queue` | only `preparing` / `running` | A queued run, which the dispatcher starts after the running one finished (below). |
| `allow` | any | A queued run. Only the concurrency limits apply. |
| any | none | A queued run. |

**`queue` keeps at most one waiting run.** Without the cap, a suite that hangs for three hours under a 15-minute schedule would leave twelve runs waiting, all testing the same thing late. The main spec says "a new run is queued and waits"; this refines what happens on the next tick.

**`queue` waits for the previous run.** An environment limit of 1 would make it wait anyway, but with a higher limit the dispatcher would start both in parallel, and `queue` would behave like `allow`. The dispatcher therefore skips a queued run whose schedule has `overlap_policy = queue` while another run of that schedule is `preparing` or `running`. It stays queued, and it does not block other runs (Milestone 3, section 5). The policy is read at dispatch time.

**Disabled test definition.** A schedule of a disabled test definition creates no run: outcome `skipped_disabled`, and the schedule still advances. It resumes by itself when the test definition is enabled again. It is not disabled for this, because the test definition was disabled, not the schedule.

The decision and the insert happen inside the schedule's transaction. Two ticks cannot both see "no unfinished run" for the same schedule, because the second waits on the row lock or skips the schedule.

---

## 6. `Runs.create_scheduled/2`

```elixir
create_scheduled(schedule, scheduled_for)
  # {:ok, run} | {:skipped, :overlap | :test_definition_disabled} | {:ok, :exists}
```

- Called by `Schedules.tick/1` inside the schedule's transaction; it does not broadcast. The tick broadcasts after the commit.
- Copies `image` and `command` from the test definition, like `create_manual_run` (Milestone 3, section 3).
- `trigger = schedule`, `schedule_id`, `scheduled_for`, `queued_at = now`.

---

## 7. Oban

```elixir
config :testfleet, Oban,
  # A top-level service in this Oban version, like pruner and lifeline.
  cron: [crontab: [{"* * * * *", TestFleet.Schedules.TickWorker}]]
```

- Cron runs only on the leader node; with one node, that is the node.
- The test environment runs Oban with `testing: :manual`, so no cron fires in tests. Tests call `Schedules.tick/1` directly, and one test checks with `Oban.Testing` that the worker calls it.
- `max_attempts: 1`: a failed tick is not retried; the next minute's tick picks up everything that is still due.

---

## 8. UI

### Schedule rows (project page)

- The last outcome below the cron expression:
  - created: "Last run #1842 [status] · Sat 27 Sep 2026, 06:00 CEST"
  - `skipped_overlap`: "Skipped … because the previous run was unfinished", with a warning tone
  - `skipped_disabled`: "Skipped … because the test definition is disabled", with a warning tone
- The run number is not a link: the row already links to the schedule's edit form, and links cannot be nested. The run is in "Recent runs" on the same page.
- Updated live: the project page already subscribes to `runs`. A schedule's row is refreshed whenever one of its runs changes, so the last run's status stays current. Skips are only visible after a reload; a skip changes no run.

### Run page

- For a scheduled run, the trigger reads "Schedule" with the cron expression and links to the schedule's edit form.
- A separate "Scheduled for" row shows the slot (`scheduled_for`) in the schedule's time zone. It differs from the queued and started times after downtime (coalesced slots) or a `queue` wait.
- If the schedule was deleted, the trigger is plain "Schedule", and "Scheduled for" remains.

### Dashboard

- "Upcoming schedules" marks a schedule as **overdue** when its `next_run_at` is more than 2 minutes in the past. While the tick works this never happens, so an overdue badge means scheduling is stuck (main spec section 48, "missed schedules"). Alerts for it come with Milestone 8.
- The panel is reloaded every minute (with the figures) and when a scheduled run is created, so it shows each schedule's next time, and a stuck tick becomes visible without a reload. Until now it was loaded only on mount.

---

## 9. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Tick: schedule columns, `Schedules.tick/1`, `Runs.create_scheduled/2` with the overlap policies, `TickWorker` and the cron plugin, the dispatcher's `queue` rule. | – |
| B | UI: last outcome on schedule rows, the schedule on the run page, overdue schedules on the dashboard. | A |

Each slice passes `mix precommit` on its own.

**Status (2026-09-27):** all slices are built (273 tests, plus 55 Docker integration tests). The manual walkthrough (section 11) is pending.

---

## 10. Tests

- **`Schedules.tick/1`** (fixed `now`):
  - a due schedule creates one queued run with `trigger = schedule`, `schedule_id`, and `scheduled_for` = the old `next_run_at`, and advances `next_run_at`
  - a schedule that is not yet due, or disabled, creates nothing
  - missed slots are coalesced into one run, and `next_run_at` lands after `now`
  - a second tick with the same `now` creates nothing
  - an existing run for the slot (unique index) counts as created
  - a disabled test definition: `skipped_disabled`, still advanced
  - a broken schedule is disabled, and the other schedules still run
  - DST: a Europe/Vienna schedule at 02:30 across both changes runs once per day
  - the outcome columns are written, `updated_at` is not
  - `run_created` is broadcast after the commit
- **Overlap policy:** every row of the table in section 5.
- **Dispatcher** (fake engine): a `queue` run waits while its schedule's previous run is active, does not block other runs, and starts once the previous run finished; an `allow` run does not wait.
- **Worker:** `perform/1` ticks.
- **LiveViews:** the outcome on schedule rows, the schedule on the run page, the overdue badge.
- **End to end** (Docker): a due schedule with the fixture image runs to `passed` through the real dispatcher.

---

## 11. Done

Milestone 5 is done when all slices pass `mix precommit` and the Docker tests, and a manual walkthrough works:

1. Create a schedule every minute (`* * * * *`) and see a run appear within a minute, `trigger = schedule`.
2. With a `hang` suite and `skip`, see the next ticks skipped and the row say so.
3. Switch to `queue`: at most one run waits, and it starts when the running one is cancelled.
4. Stop TestFleet for a few minutes and start it again: one run for the missed slots, not one per minute.
5. Disable the test definition: the schedule skips and resumes when it is enabled again.
