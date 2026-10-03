---
title: Schedules
description: Run a suite against an environment on a cron schedule, in any time zone.
---

A schedule runs one test definition against one environment of the same project, on a cron expression, in a time zone you choose.

```text
E2E against production    0 6 * * 1-5    Europe/Vienna    skip
```

## Cron expression

Standard five-field cron: minute, hour, day of month, month, day of week.

| Expression     | Runs                              |
| -------------- | --------------------------------- |
| `0 6 * * *`    | Every day at 06:00                |
| `0 6 * * 1-5`  | Weekdays at 06:00                 |
| `*/15 * * * *` | Every 15 minutes                  |
| `0 * * * *`    | Every hour, on the hour           |
| `30 2 1 * *`   | 02:30 on the first of every month |

Aliases such as `@daily` and `@hourly` work too; `@reboot` does not. Expressions that can never match, such as `0 0 30 2 *`, are refused. The form offers presets and previews the next three run times while you type.

Schedules have minute precision. A run is created within a few seconds after its minute.

## Time zone

The expression is evaluated on the wall clock of the schedule's time zone (any IANA name, such as `Europe/Vienna` or `America/New_York`), so "06:00" stays 06:00 local time across daylight saving changes.

On the two nights a year when the clock changes:

- **Spring forward:** a time that does not exist (02:30 when clocks jump from 02:00 to 03:00) runs at the first moment after the gap, 03:00.
- **Fall back:** a time that occurs twice runs only the first time.

Every local time runs at most once. A side effect: a schedule that runs every few minutes pauses during the repeated hour, because those local times already ran.

Times are shown in the schedule's time zone with its abbreviation (`Sat 27 Sep 2026, 06:00 CEST`); hover for UTC.

## Overlap policy

What happens when the schedule fires while its previous run is still queued, preparing, or running:

| Policy             | Behaviour                                                                                                                                          |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| **skip** (default) | No new run. The schedule records the skip, visible on its row.                                                                                     |
| **queue**          | A new run is queued and starts after the previous one finished. **At most one** run waits: a further tick while one is already waiting is skipped. |
| **allow**          | A new run is created regardless; only the concurrency limits apply.                                                                                |

Only the schedule's own runs count. A manual or API run of the same suite does not block a schedule.

`skip` suits most suites: if the 06:00 run is still going at 06:15, another run tests nothing new. `queue` suits schedules where every slot matters, without letting a hanging suite pile up runs behind it.

## Downtime and missed slots

If TestFleet was down when slots were due, the schedule creates **one** run for the oldest missed slot when it is back, then continues with the next regular slot. A schedule every 15 minutes after two hours of downtime creates one catch-up run, not eight. The run page shows both the slot it was **scheduled for** and when it was actually queued.

A slot never produces two runs, even if several TestFleet processes or ticks race for it.

## Disabled test definitions

When a schedule fires for a disabled test definition, it records "skipped because the test definition is disabled" and moves on to its next slot. It resumes by itself when the test definition is enabled again.

## Watching schedules

- Each schedule's row on the project page shows its last outcome: the run it created and its status, or why it skipped.
- The dashboard lists upcoming schedules and marks one **overdue** when it is more than 2 minutes late. That only happens when scheduling itself is stuck.
- An admin can subscribe a notification channel to `system.scheduling_stalled`, sent when any schedule is more than 10 minutes overdue. See [Notifications](/guides/notifications/#system-events).
- For the case TestFleet cannot report itself (the whole server is down), set `HEARTBEAT_URL` to an external dead man's switch such as Healthchecks.io. TestFleet pings it after every schedule tick; the external service alerts when the pings stop.
