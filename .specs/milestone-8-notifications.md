# TestFleet — Milestone 8: Notifications

## 1. Purpose

Milestone 8 tells people when something changes: a suite starts failing, recovers, or cannot run because of the infrastructure, and TestFleet itself stops scheduling or loses Docker. Messages go to email, Slack, Microsoft Teams, and generic webhooks.

The rule behind it is the main spec's: **notify on transitions, not on every run** (section 48). A suite that stays red is reported once, and again when it recovers.

```text
run finished (Runs.finish, one transaction)
  ↓ Oban job, inserted in the same transaction
Notifications.EvaluateWorker: did this run change its series' state?
  ↓ one delivery per matching channel
Notifications.DeliveryWorker: email · Slack · Teams · webhook (retried)
```

The main spec ([tech-architecture-execution-spec.md](tech-architecture-execution-spec.md)) defines the `NotificationWorker` (section 28), notifications on transitions and missed schedule alerts (section 48), and the milestone (section 52). Milestone 5 left the dashboard's "overdue" badge waiting for these alerts ([milestone-5-scheduling.md](milestone-5-scheduling.md), section 8); Milestone 7 moved alerts about Docker here ([milestone-7-reliability.md](milestone-7-reliability.md), section 2). This document records what the main spec leaves open.

---

## 2. Scope

### In scope

- Channels: email (SMTP), Slack, Microsoft Teams, generic webhooks, with their secrets encrypted
- Subscriptions: which events of which projects and environments go to which channel
- Run events: a series starts failing, recovers, or ends in an infrastructure error
- System events: Docker unreachable for a while, scheduling stalled, and their recovery
- A heartbeat ping to an external dead man's switch
- Delivery with retries, and a delivery log
- UI: a Notifications page (channels, subscriptions, "Send test", recent deliveries), deliveries on the run page

### Out of scope

| What | When |
|------|------|
| Per-user preferences, "my" subscriptions | with authentication (deferred) |
| Reminders for a suite that stays red (for example daily) | later; the main spec calls it optional |
| Batching several events into one message | later |
| Chat apps with bot tokens (Slack apps, Teams bots), threads, reactions | never planned; incoming webhooks are enough |
| Metrics (Prometheus) | later (main spec section 47) |

---

## 3. Decisions to Confirm

**All four defaults were approved (2026-09-28).**

| # | Question | Default |
|---|----------|---------|
| 1 | Do manual and API runs notify, or only scheduled ones? | All triggers. One pipeline (main spec section 29), and transitions already keep the noise down. The message says which trigger it was. |
| 2 | Does `timeout` count as failing? | Yes: a suite that hangs is most often the application hanging. The message says "timed out". |
| 3 | Teams: which kind of webhook? | Workflows webhooks ("When a Teams webhook request is received"), which take Adaptive Cards. Microsoft retired the Office 365 connectors. |
| 4 | Email transport | SMTP, configured through environment variables, with `gen_smtp` as a new dependency (Swoosh's SMTP adapter needs it). |

---

## 4. Channels

A channel is one destination. Channels are global: without authentication there are no users to own them.

| Kind | Target | Secret |
|------|--------|--------|
| `email` | a list of addresses | none (SMTP credentials are server configuration, section 8) |
| `slack` | a Slack incoming webhook URL | the URL |
| `teams` | a Teams Workflows webhook URL | the URL |
| `webhook` | any `http(s)` URL | the URL, and an optional signing secret |

**A webhook URL is a credential.** Slack's and Teams' URLs carry their token in the path, and a generic webhook may too. They are handled like registry passwords (Milestone 2, section 5):

- encrypted at rest with `TestFleet.Encrypted.Binary` (`redact: true`)
- never sent to the browser after saving: the list and the edit form show only the host, as `hooks.slack.com/…`, stored separately as `url_hint`; the edit form's URL field is empty with "leave empty to keep the current URL"
- never logged: errors name the channel and the HTTP status, never the URL; Oban job arguments carry ids only, because Oban stores them as plain JSON
- the signing secret works the same way

Validation: a name (unique), a kind, and for email at least one address (up to 20, each checked for a basic `local@domain` form). URLs must be `http` or `https` with a host. The Slack and Teams URLs are not restricted to Microsoft's or Slack's hosts, so compatible services (for example Mattermost) work.

**Send test.** Each channel has "Send test", on the saved channel and in the form before saving (with the form's values; an empty URL on the edit form uses the stored one, as "Test connection" does for registries). It sends a `test` event synchronously, not through Oban, and shows the result: "Delivered" or the error.

**Known risk (no authentication yet):** anyone who can open TestFleet can point a webhook at an internal address, and TestFleet will POST to it. Redirects are not followed, and responses are not shown beyond their status and a short error. This is revisited with authentication.

---

## 5. Subscriptions

A subscription connects a channel to events, optionally limited to a project, or to one environment of a project.

- `notification_subscriptions`: `channel_id`, `project_id` (nullable), `environment_id` (nullable; requires `project_id`, and must belong to that project), `events` (array of event names, at least one).
- A channel can have several subscriptions, for example "failing and recovered of project A" and "errors of everything".
- **System events** can only be chosen in a subscription without a project: they belong to no project.
- An event that matches several subscriptions of one channel is delivered once to that channel.
- Deleting a project or environment deletes its subscriptions; deleting a channel deletes its subscriptions and deliveries.

### Events

| Event | When | Scope |
|-------|------|-------|
| `run.failing` | A series turns red | project, environment |
| `run.recovered` | A red series turns green | project, environment |
| `run.error` | A run ends `error` after a run that did not | project, environment |
| `system.docker_unreachable` | Docker has been unreachable for 5 minutes | global |
| `system.docker_recovered` | Docker is reachable again, after an alert | global |
| `system.scheduling_stalled` | An enabled schedule is overdue by more than 10 minutes | global |
| `system.scheduling_recovered` | No schedule is overdue any more, after an alert | global |
| `test` | "Send test" | – |

New subscriptions preselect `run.failing`, `run.recovered`, and `run.error`.

---

## 6. Run Events

### Series and verdicts

A **series** is all runs of one test definition in one environment. Each final run has a **verdict**:

| Status | Verdict |
|--------|---------|
| `passed` | green |
| `failed`, `timeout` | red |
| `error` | none: an infrastructure problem says nothing about the application |
| `cancelled` | none, and ignored entirely |

### Rules

For a run that just became final, with the previous runs of its series ordered by id (creation order; runs of one series may finish out of order under the `allow` overlap policy, and the id keeps the evaluation deterministic):

| Run | Compared with | Event |
|-----|---------------|-------|
| red | the latest earlier run with a verdict is green, or there is none | `run.failing` |
| red | … is red | nothing (still failing) |
| green | the latest earlier run with a verdict is red | `run.recovered` |
| green | … is green, or there is none | nothing |
| `error` | the latest earlier non-cancelled run is not `error` | `run.error` |
| `error` | … is `error` | nothing (still broken) |
| `cancelled` | – | nothing |

So `passed → error → failed` reports the error and the failure; `failed → error → passed` reports the error and the recovery; the first run of a new suite reports only if it is red.

The rules are a pure function, `TestFleet.Notifications.Transitions.event/2`, tested without the database.

### Evaluation

- **Every path that makes a run final** (`Runs.finish/2`, `Runs.fail/2`, `Runs.mark_cancelled/1`, cancelling a queued run) inserts a `Notifications.EvaluateWorker` job **in the same transaction**. A run that is final always gets evaluated, even if TestFleet dies right after the commit; PubSub is not used for this, because it is only transport.
- `EvaluateWorker` (queue `notifications`, `max_attempts: 3`) loads the run and its series, decides the event, finds the matching subscriptions, and inserts one delivery per channel, each with its own `DeliveryWorker` job, in one transaction.
- Deliveries are unique per `(channel_id, dedupe_key)`, with `dedupe_key` = `"run.failing:<run_id>"` etc. A retried evaluation cannot notify twice.
- Cancelled runs are evaluated too, and produce nothing. That keeps "every final run is evaluated" free of exceptions.

---

## 7. System Events

`TestFleet.Notifications.Watchdog`, a GenServer (not Oban: it must notice when Oban's cron is stuck), checks once a minute:

- **Docker:** `Execution.docker_status/0` (Milestone 7, section 7). Unreachable for 5 minutes (`docker_alert_after`) → `system.docker_unreachable`, with the time and the message. Reachable again after that alert → `system.docker_recovered`. Short outages, like a socket proxy restart, stay quiet.
- **Scheduling:** enabled schedules of enabled test definitions whose `next_run_at` is more than 10 minutes in the past (`schedule_alert_after`). While the tick works this never happens (Milestone 5, section 8). Any found → **one** `system.scheduling_stalled` listing them (up to 10, and "and N more"); none any more after that alert → `system.scheduling_recovered`. A stuck tick makes every schedule overdue at once, and one message says it better than fifty.
- An episode (from the alert to the recovery) alerts once. The episode state is kept in the process: after a restart during an outage, it alerts again. That is accepted, and simpler than persisting it.
- Delivery keys: `"system.docker_unreachable:<unix time the episode started>"`, and the same for the others.

### Heartbeat

`HEARTBEAT_URL` (optional): after each completed schedule tick, `TickWorker` sends `GET <url>` in a task (timeout 10 s, no retries), for an external dead man's switch such as Healthchecks.io. The external system alerts when the pings stop, which covers TestFleet being entirely down, the one case TestFleet cannot report itself (main spec section 48). A failing ping is logged once per failure streak, never with the URL.

---

## 8. Delivery

### Deliveries

`notification_deliveries`: `channel_id`, `event`, `dedupe_key`, `run_id` (nullable), `data` (map, for system events: times, counts, schedule names; never secrets), `status` (`pending`, `sent`, `failed`), `attempts`, `last_error` (short, never the URL or a response body), `sent_at`, timestamps. Unique `(channel_id, dedupe_key)`.

`DeliveryWorker` (queue `notifications`, `max_attempts: 5`, Oban's backoff) takes a delivery id, renders the message from current data, and sends it:

- `2xx` → `sent`.
- `429`, `5xx`, transport errors → retried; `failed` after the last attempt.
- Other `4xx` (a revoked Slack URL answers `404` or `410`) → `failed` at once (`{:cancel, reason}`): retrying cannot help.
- A disabled channel, or a deleted run → `failed` with the reason, not sent.

Retrying deliveries does not conflict with "no automatic retries" (AGENTS.md): that rule is about runs.

All HTTP goes through `Req` with `retry: false` (Oban retries), `redirect: false`, and a 10-second timeout.

### Messages

Rendered at send time by `TestFleet.Notifications.Message`, one struct per event: a title, a short summary, facts, and a link. Kind-specific formatters turn it into an email, Slack blocks, an Adaptive Card, or webhook JSON.

Example, `run.failing`:

```text
Customer Portal E2E is failing on production
Failed after 4 min 12 s · 3 of 48 tests failed · scheduled run
First failures: checkout › pays with card, login › rejects wrong password, …
Previous run passed · Open run #1234
```

- The link is the run page, absolute, from the endpoint's URL (`PHX_HOST`).
- Up to 3 failing test **names**, never their messages or any log output: failure messages and logs can carry data the team would not post to a channel. The run page has the rest.
- `run.error` includes the run's `error_message` (TestFleet's own text, for example "Docker was interrupted…").
- Environment variables are never part of a message, not even their names.

### Formats

- **Email:** subject `[TestFleet] <title>`, a plain text and a simple HTML part. From `SMTP_FROM`. One email per channel, all addresses in `To`.
- **Slack:** `{"text": <title>, "blocks": [...]}`: a section with the title and summary, fields for the facts, a button "Open run".
- **Teams:** `{"type": "message", "attachments": [{"contentType": "application/vnd.microsoft.card.adaptive", "content": <Adaptive Card 1.4>}]}`, with the same parts and an `Action.OpenUrl`.
- **Webhook:** JSON, versioned:

  ```json
  {
    "version": 1,
    "event": "run.failing",
    "delivery_id": 81,
    "occurred_at": "2026-09-28T14:02:11Z",
    "run": {"id": 1234, "status": "failed", "trigger": "schedule", "url": "https://…/runs/1234",
            "started_at": "…", "finished_at": "…", "duration_ms": 252000, "exit_code": 1,
            "error_message": null, "tests": {"passed": 45, "failed": 3, "skipped": 0}},
    "previous_status": "passed",
    "test_definition": {"id": 7, "name": "Customer Portal E2E", "slug": "customer-portal-e2e"},
    "project": {"id": 2, "name": "Customer Portal", "slug": "customer-portal"},
    "environment": {"id": 5, "name": "production"}
  }
  ```

  System events carry `"system": {...}` instead of the run, test definition, project, and environment. Headers: `X-TestFleet-Event`, `X-TestFleet-Delivery` (for idempotency on the receiver), and with a signing secret `X-TestFleet-Timestamp` and `X-TestFleet-Signature: sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`.

### Email configuration

`config :testfleet, TestFleet.Mailer` from the environment in `config/runtime.exs`, for production:

| Variable | Default |
|----------|---------|
| `SMTP_HOST` | – (without it, email is not configured) |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME`, `SMTP_PASSWORD` | none |
| `SMTP_TLS` | `if_available` (`always`, `never`) |
| `SMTP_FROM` | `testfleet@<PHX_HOST>` |

Development keeps Swoosh's local adapter and `/dev/mailbox`; tests keep the test adapter. Without SMTP in production, email channels can be saved, but show "Email is not configured on this server", and their deliveries fail with that message.

### Retention

The `CleanupWorker` (Milestone 7, section 8) gets a fourth step: deliveries older than 90 days are deleted.

---

## 9. UI

- **Navigation:** a "Notifications" entry, `/notifications`.
- **Notifications page:**
  - Channels panel: name, kind icon, target (addresses, or the URL hint), enabled, the status of the latest delivery. Actions: edit, send test, enable/disable, delete (with confirmation).
  - Channel form (`/notifications/channels/new`, `/…/:id/edit`): kind-specific fields, the secret fields as in section 4, "Send test".
  - Subscriptions, per channel: scope ("All projects", a project, or a project's environment) and event checkboxes, grouped into run events and system events; system events are disabled unless the scope is "All projects".
  - Recent deliveries: the last 50, streamed, live: time, channel, event, run link, status, last error.
- **Run page:** a small "Notifications" line when the run caused deliveries: "Sent to #e2e-alerts, QA email", or the failure.
- **Dashboard:** unchanged. The overdue badge (Milestone 5) now has an alert behind it.

---

## 10. Data Model Changes

| Change | Purpose |
|--------|---------|
| `notification_channels`: `name` (unique), `kind`, `enabled`, `email_recipients` (array), `url_encrypted`, `url_hint`, `signing_secret_encrypted`, timestamps | Channels (section 4) |
| `notification_subscriptions`: `channel_id`, `project_id`, `environment_id`, `events` (array), timestamps | Subscriptions (section 5) |
| `notification_deliveries`: as in section 8, unique `(channel_id, dedupe_key)`, index on `run_id`, index on `inserted_at` | Deliveries and their log |

---

## 11. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Channels: schema with encrypted secrets, the four senders (email with SMTP configuration and `gen_smtp`, Slack, Teams, webhook with signing), the channel UI with "Send test". Deliveries table and `DeliveryWorker` with its retry rules, used by "Send test" only through the senders. | – |
| B | Run events: subscriptions and their UI, `Transitions.event/2`, `EvaluateWorker` inserted in every finalizing transaction, deliveries per channel, the delivery log, the run page line. | A |
| C | System events: `Watchdog` (Docker, scheduling stalled, recoveries), the heartbeat, pruning deliveries. | B |

Each slice passes `mix precommit` on its own. The existing Docker tests keep passing.

**Status (2026-09-28):** slices A and B are built (458 tests, plus 84 Docker integration tests).

Notes from slice B:

- The evaluation job is inserted in `Runs`' single status update (`update_status/3`) whenever the new status is final. Every status change now runs in a transaction; `Runs.finish/2` already did.
- **Disabled channels get no delivery at all** (not a failed one): evaluation only looks at enabled channels. A channel disabled between evaluation and sending still fails its delivery with "the channel is disabled".
- Subscriptions are managed on the channel's page, below its settings. A new channel opens there after saving ("Now choose what it receives"); the channel list shows "receives nothing yet" for a channel without subscriptions. A subscription is changed by removing it and adding another.
- `run.error` names the run right before it (the latest non-cancelled one) as the previous run; that run always has a verdict when the event fires.
- The webhook payload also carries `run.failed_tests`: the same up to three names as the message.
- Deliveries are broadcast on the `notifications` topic with their channel redacted; the delivery log and the run page follow them live.
- **Known limit:** two runs of one series that run in parallel (`allow` overlap) and both fail right after a green run can both report `run.failing`: each is evaluated against the runs that were final when it finished.

Notes from slice A:

- Configuration: `config :testfleet, TestFleet.Notifications` with `email_enabled` (false in production without `SMTP_HOST`), `email_from`, and `req_options` (the tests route Slack, Teams, and webhook requests to a `Req.Test` stub).
- The URL hint is the host, followed by `/…` when the URL has a path or query (`hooks.slack.com/…`); a bare `http://receiver:8080` shows as `receiver`.
- A signing secret has at least 16 characters. The edit form has "Remove the signing secret".
- `Notifications.enqueue_delivery/4` (and `enqueue_delivery_multi/6`, for callers with their own transaction, as slice B's evaluation) inserts the delivery and its job in one transaction; a duplicate `dedupe_key` returns `{:ok, :duplicate}` and inserts no job.
- `DeliveryWorker` renders only `test` so far; any other event fails permanently until slices B and C add theirs.
- "Send test" results are shown, not stored as deliveries.
- `redact: true` keeps the URL and the secret out of `inspect/1`, and so out of crash reports and logs.

---

## 12. Tests

- **Channels:** secrets are encrypted in the database (the raw column is not the URL); the URL never appears in rendered HTML, in LiveView assigns sent to the client, or in Oban job args; the edit form keeps the URL when left empty; validation of kinds, addresses, and URLs.
- **Senders**, against `Req.Test` stubs: the Slack, Teams, and webhook payloads; the webhook signature (verified with the secret); status handling (`2xx` sent, `5xx` and transport errors retried, `4xx` cancelled, `429` retried); no redirect followed. Email with `Swoosh.TestAssertions`.
- **`Transitions.event/2`:** every row of section 6, including errors between verdicts, cancelled runs, the first run, and out-of-order finishing.
- **Evaluation:** each finalizing path inserts the job in its transaction; one delivery per channel when several subscriptions match; scopes (all, project, environment) and event filters; running the job twice notifies once.
- **Watchdog:** with a fake Docker status and overdue schedules: alerts after the delay, once per episode, one message for many schedules, recovery after an alert only.
- **Heartbeat:** pinged after a tick with a `Req.Test` stub; not configured, nothing is sent.
- **LiveViews:** channel CRUD and "Send test", subscriptions with system events limited to "All projects", the delivery log updating live, the run page line.

---

## 13. Done

Milestone 8 is done when all slices pass `mix precommit`, the Docker tests still pass, and a manual walkthrough works:

1. Create a webhook channel pointing at a local receiver (`docker run --rm -p 8088:8080 mendhak/http-https-echo`), with a signing secret. "Send test" shows "Delivered", and the receiver's log shows the payload and the signature headers. The edit page does not show the URL.
2. Create an email channel. "Send test" arrives in `/dev/mailbox`.
3. Subscribe both to a project's run events. Run a suite that passes, then one that fails (`SPIKE_MODE=fail`), then fails again, then passes: exactly one "failing" and one "recovered" arrive, and the run page shows where they went.
4. Make a run end `error` (an image that does not exist): one "error" arrives; a second in a row stays quiet.
5. Stop the socket proxy for 6 minutes: "Docker unreachable" arrives after 5; starting it sends "Docker recovered". A 1-minute stop stays quiet.
6. Point a channel at a URL that answers `500` (stop the receiver): the delivery is retried, then shows `failed` with the error in the log.
7. If you have them: a Slack incoming webhook and a Teams Workflows webhook, each receiving "Send test" and a run event.
