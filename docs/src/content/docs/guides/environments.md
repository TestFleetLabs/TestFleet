---
title: Environments and secrets
description: Point suites at target systems with variables and secrets, and limit how many runs hit an environment at once.
---

An environment is a target a suite runs against: staging, production, a customer's instance. It belongs to a project and holds the variables the suite needs to reach it.

## Variables

Every variable is passed to the suite's container as an environment variable.

- **Key:** letters, digits, and underscores, not starting with a digit. Keys starting with `TestFleet_` (in any case) are reserved for [the variables TestFleet sets](/suites/container-contract/#input-environment-variables-only).
- **Value:** any text. All values are encrypted at rest, secret or not.

Typical variables:

```text
BASE_URL        https://staging.portal.example.com
API_URL         https://api.staging.example.com
E2E_USER        e2e-bot@example.com
E2E_PASSWORD    ••••••••              secret
```

### Secrets

Mark a variable as **secret** for passwords, tokens, and keys. A secret value:

- is never sent back to the browser after saving: the list shows `••••••`, and the edit form leaves the value empty ("leave empty to keep the current value")
- is **masked in the run's log**: every occurrence is replaced with `[MASKED]` before the line is stored or streamed, so a suite that prints its configuration or request headers does not leak it
- must be at least 6 characters long, because shorter values cannot be masked reliably
- can only be made non-secret again by entering a new value

```text
POST /api/session  {"user": "e2e-bot@example.com", "password": "[MASKED]"}
```

:::caution[What masking cannot do]
Masking replaces the exact value. A suite that prints a secret transformed (base64-encoded, URL-encoded, split across lines) is not masked. Notifications never include variables, not even their names. Anyone with access to the Docker host can still see the values with `docker inspect`.
:::

## Concurrency

Each environment has a **maximum number of concurrent runs**, from 1 to 100, and **1 by default**: a new environment is protected until you deliberately raise the limit.

```text
Global limit (MAX_CONCURRENT_RUNS, default 10)
  ├── Customer Portal / production    1
  ├── Customer Portal / staging       5
  └── Billing / production            1
```

A run starts only when both limits allow it: fewer than 10 runs in total are preparing or running, and fewer than the environment's limit against this environment. Otherwise it stays `queued` and starts as soon as a slot frees up, oldest first. A run waiting for a busy environment never holds up runs for other environments.

Because environments belong to a project, the limit protects one application's environment. "Production" of two different projects are independent.

Limits matter most for production: E2E suites log in, create orders, and load pages like real users. A limit of 1 keeps a manual run, a schedule, and a pipeline from piling onto the same system at once.

## Running against an environment

- **Run now** on a test definition's page lists the project's environments.
- A [schedule](/guides/schedules/) combines one test definition with one environment.
- The [API](/ci/api/#start-a-run) names the environment by its slug.

Variables are read when a run leaves the queue to start. A change therefore applies to runs that are still queued, but not to runs that are already preparing or running.
