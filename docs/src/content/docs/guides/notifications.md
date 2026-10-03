---
title: Notifications
description: Send email, Slack, Microsoft Teams, and webhook messages when a suite starts failing, recovers, or cannot run.
---

TestFleet tells people when something **changes**: a suite starts failing, recovers, or cannot run because of the infrastructure. A suite that stays red is reported once, and again when it is green. Notifications are managed by admins under **Notifications**.

## Channels

A channel is one destination.

| Kind                | Target                                                                                                                     |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------- |
| **Email**           | Up to 20 addresses, all in one message. Needs [SMTP](/operate/configuration/#email-smtp).                                  |
| **Slack**           | A Slack [incoming webhook](https://api.slack.com/messaging/webhooks) URL. Compatible services such as Mattermost work too. |
| **Microsoft Teams** | A Teams **Workflows** webhook URL ("When a Teams webhook request is received"). Messages are Adaptive Cards.               |
| **Webhook**         | Any `http(s)` URL that accepts a JSON `POST`, optionally signed                                                            |

Webhook URLs carry their own credentials, so TestFleet treats them as secrets: encrypted at rest, never shown again after saving (the list shows only the host, as `hooks.slack.com/…`), and never written to logs.

**Send test** on a channel, or in its form before saving, sends a test message right away and shows "Delivered" or the error.

## Subscriptions

A channel receives nothing until it has a **subscription**: which events, from where. A subscription's scope is all projects, one project, or one environment of a project. A channel can have several subscriptions, for example "failing and recovered of the Customer Portal" and "errors of everything". An event that matches several subscriptions of one channel is delivered to it once.

New subscriptions preselect the three run events.

### Run events

A **series** is all runs of one test definition in one environment. Each event compares a finished run with the series' previous runs:

| Event           | Sent when                                                                                              |
| --------------- | ------------------------------------------------------------------------------------------------------ |
| `run.failing`   | A run is red (`failed` or `timeout`), and the previous run with a verdict was green, or there was none |
| `run.recovered` | A run passed, and the previous run with a verdict was red                                              |
| `run.error`     | A run ended `error`, and the previous (non-cancelled) run did not                                      |

`error` runs say nothing about the application, so they do not count as red or green, and cancelled runs are ignored. For example, `passed → error → failed` sends an error and a failing; `failed → error → passed` sends an error and a recovered.

All triggers notify: scheduled, manual, and API runs. The message says which it was.

```text
Customer Portal E2E is failing on production
Failed after 4 min 12 s · 3 of 48 tests failed · scheduled run
First failures: checkout › pays with card, login › rejects wrong password, …
Previous run passed · Open run #1234
```

A message names at most three failing tests, never their failure messages, log output, or any environment variable: those can contain data a team would not post to a chat channel. The run page has the rest.

### System events

These can only be subscribed with the scope "All projects":

| Event                         | Sent when                                                                    |
| ----------------------------- | ---------------------------------------------------------------------------- |
| `system.docker_unreachable`   | TestFleet has not reached Docker for 5 minutes                               |
| `system.docker_recovered`     | Docker is reachable again, after that alert                                  |
| `system.scheduling_stalled`   | Any enabled schedule is more than 10 minutes overdue; one message lists them |
| `system.scheduling_recovered` | No schedule is overdue any more, after that alert                            |

Short outages, such as a restart of the socket proxy, stay quiet. For TestFleet being down entirely, which it cannot report itself, use the [heartbeat](/guides/schedules/#watching-schedules).

## Delivery

Messages are sent in the background and retried: server errors, `429`, and network failures up to 5 attempts with increasing delays. Other `4xx` answers fail at once, because a revoked Slack URL will not start working on a retry. Redirects are not followed.

The Notifications page shows the last 50 deliveries live, with their status and error. A run's page shows where its notifications went. Deliveries are kept for 90 days.

## Webhook payload

A webhook channel receives JSON:

```json
{
  "version": 1,
  "event": "run.failing",
  "delivery_id": 81,
  "occurred_at": "2026-09-28T14:02:11Z",
  "run": {
    "id": 1234,
    "status": "failed",
    "trigger": "schedule",
    "url": "https://testfleet.example.internal/runs/1234",
    "started_at": "2026-09-28T13:57:59Z",
    "finished_at": "2026-09-28T14:02:11Z",
    "duration_ms": 252000,
    "exit_code": 1,
    "error_message": null,
    "tests": { "passed": 45, "failed": 3, "skipped": 0 },
    "failed_tests": ["checkout › pays with card", "…"]
  },
  "previous_status": "passed",
  "test_definition": { "id": 7, "name": "Customer Portal E2E", "slug": "customer-portal-e2e" },
  "project": { "id": 2, "name": "Customer Portal", "slug": "customer-portal" },
  "environment": { "id": 5, "name": "production" }
}
```

`run.failed_tests` holds up to three names, for `run.failing` only; other events send an empty list. System events carry a `"system"` object instead of `run`, `test_definition`, `project`, and `environment`.

Headers:

| Header                  | Value                                                                           |
| ----------------------- | ------------------------------------------------------------------------------- |
| `X-TestFleet-Event`     | The event, such as `run.failing`                                                |
| `X-TestFleet-Delivery`  | The delivery id; the same on every retry, so the receiver can ignore duplicates |
| `X-TestFleet-Timestamp` | With a signing secret: Unix time of the request                                 |
| `X-TestFleet-Signature` | With a signing secret: `sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`       |

### Verifying the signature

Give the channel a signing secret of at least 16 characters, then check every request on the receiver. In Node.js:

```js
import { createHmac, timingSafeEqual } from "node:crypto"

function verify(req, rawBody, secret) {
  const timestamp = req.headers["x-testfleet-timestamp"]
  const signature = req.headers["x-testfleet-signature"] ?? ""
  const expected =
    "sha256=" + createHmac("sha256", secret).update(`${timestamp}.${rawBody}`).digest("hex")

  const fresh = Math.abs(Date.now() / 1000 - Number(timestamp)) < 300
  return (
    fresh &&
    signature.length === expected.length &&
    timingSafeEqual(Buffer.from(signature), Buffer.from(expected))
  )
}
```

Compute the HMAC over the raw request body as received, not over re-serialized JSON, which may differ in whitespace or key order.
