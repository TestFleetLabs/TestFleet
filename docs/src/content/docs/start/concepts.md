---
title: Concepts
description: The organization, projects, test definitions, environments, schedules, runs, and how they relate.
---

```text
Organization                   your company or team: its people, registries, and channels
  └── Project                  an application, such as "Customer Portal"
        ├── Test definition    which image to run, with which command, timeout, and limits
        ├── Environment        where to test: variables, secrets, a concurrency limit
        └── Schedule           when: a test definition × an environment × a cron expression

Run                            one execution of a test definition against an environment
```

## Organization

Everything belongs to one organization, named when TestFleet is set up. Its slug starts every page's URL: `/acme/projects/customer-portal`. See [Your organization](/guides/users/#your-organization).

## Project

A project groups everything that belongs to one application. Projects, test definitions, and environments each have a **slug** (`customer-portal`, `e2e`, `staging`), which appears in URLs and is how the [API](/ci/api/) names them.

## Test definition

A test definition describes **what** to run: the suite's image (`ghcr.io/acme/portal-e2e:1.4.2`), an optional command, a timeout, and resource limits. A project can have several, for example a fast smoke suite and a full regression suite.

See [Test definitions](/guides/test-definitions/).

## Environment

An environment describes **where** to test: a target system such as staging or production, given to the suite as environment variables (`BASE_URL`, a test user's password). Values are encrypted at rest; secret ones are also hidden in the UI and masked in logs.

Environments belong to a project, so "production" of the Customer Portal and "production" of the Billing app are different environments, with their own variables and their own concurrency limit.

See [Environments and secrets](/guides/environments/).

## Schedule

A schedule runs one test definition against one environment on a cron expression, in a time zone of your choice: "the E2E suite against production, every day at 06:00 Europe/Vienna".

See [Schedules](/guides/schedules/).

## Run

A run is one execution. It is created by **Run now** in the UI, by a schedule, or through the API, and all three go through the same pipeline: the run is queued, admitted when the concurrency limits allow, executed in its own container, and finished with a status.

A run records exactly what it executed: the image as configured, the **digest** it resolved to, and the command. Changing the test definition afterwards does not change past runs.

### Statuses

| Status      | Meaning                                                                                                    |
| ----------- | ---------------------------------------------------------------------------------------------------------- |
| `queued`    | Created, waiting to be admitted under the concurrency limits                                               |
| `preparing` | Pulling the image and creating the container                                                               |
| `running`   | The suite is executing                                                                                     |
| `passed`    | The suite completed and all tests passed                                                                   |
| `failed`    | The suite ran, and one or more tests failed                                                                |
| `timeout`   | The suite ran longer than the test definition's timeout                                                    |
| `cancelled` | A user (or the API) cancelled it                                                                           |
| `error`     | TestFleet could not run the suite: registry, image, Docker, a crash outside the tests, or the memory limit |

The difference between `failed` and `error` matters: `failed` says something about your application, `error` says something about the infrastructure. Notifications, dashboards, and CI scripts treat them differently. See [how the final status is decided](/guides/runs/#how-the-final-status-is-decided).

## Users and roles

Everyone logs in. **Members** can do everything around testing: projects, test definitions, environments, schedules, and runs. **Admins** also manage the organization's members, registry credentials, and notification channels. See [Users and access](/guides/users/).
