---
title: API reference
description: The TestFleet HTTP API, version 1. Start and cancel runs, read their status, log, and artifacts, and update a test definition's image.
---

The API is for pipelines and scripts. It lives under `/api/v1`; a later incompatible version would get a new path.

## Conventions

- **Authentication:** every request sends an [API token](/guides/users/#api-tokens) as `Authorization: Bearer tf_…`. The API never uses a browser session.
- **Bodies** are JSON, sent with `Content-Type: application/json`. A body sent as a form (`curl -d` without that header) is refused with `400`.
- **Unknown fields** in a body are refused with `422`, so a typo such as `"enviroment"` fails instead of being ignored.
- **Names:** projects, test definitions, and environments by their slugs, as in the web UI's URLs; runs by their id.
- **Times** are ISO 8601 in UTC.
- **URLs** in responses are absolute, built from `PHX_HOST`.

### Errors

```json
{
  "error": {
    "code": "not_found",
    "message": "No environment \"stagign\" in project \"customer-portal\"."
  }
}
```

| Status | `code`                     | When                                                                                                       |
| ------ | -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| 400    | `bad_request`              | The body is not JSON, or not an object                                                                     |
| 401    | `unauthorized`             | The token is missing, unknown, expired, or its user is deactivated. Comes with `WWW-Authenticate: Bearer`. |
| 404    | `not_found`                | Unknown project, test definition, environment, run, or artifact; the message names which                   |
| 409    | `test_definition_disabled` | Starting a run of a disabled test definition                                                               |
| 410    | `expired`                  | The run's log or artifacts were removed by [retention](/suites/results-and-artifacts/#retention)           |
| 422    | `invalid`                  | Validation failed; `details` lists messages per field                                                      |

```json
{
  "error": {
    "code": "invalid",
    "message": "The request is invalid.",
    "details": { "tag": ["is not a valid tag"] }
  }
}
```

## Endpoints

| Method  | Path                                                                         |                           |
| ------- | ---------------------------------------------------------------------------- | ------------------------- |
| `POST`  | [`/api/v1/projects/:project/runs`](#start-a-run)                             | Start a run               |
| `GET`   | [`/api/v1/runs/:id`](#get-a-run)                                             | A run's status and result |
| `POST`  | [`/api/v1/runs/:id/cancel`](#cancel-a-run)                                   | Cancel a run              |
| `GET`   | [`/api/v1/runs/:id/log`](#get-the-log)                                       | The run's log, as text    |
| `GET`   | [`/api/v1/runs/:id/artifacts`](#list-artifacts)                              | The run's artifacts       |
| `GET`   | [`/api/v1/runs/:id/artifacts/*name`](#download-an-artifact)                  | One artifact's file       |
| `GET`   | [`/api/v1/projects/:project/test-definitions/:slug`](#get-a-test-definition) | A test definition         |
| `PATCH` | [`/api/v1/projects/:project/test-definitions/:slug`](#update-the-image)      | Update its image          |

## Start a run

```http
POST /api/v1/projects/customer-portal/runs
Content-Type: application/json

{"test_definition": "e2e", "environment": "staging"}
```

`201 Created`, with `Location: /api/v1/runs/1842` and the [run](#the-run-object). The run is `queued` and goes through the same queue and limits as every other run. It is recorded as started through the API by the token's user, and the run page names the token.

Errors: `404` for an unknown project, test definition, or environment (or an environment of another project), `409` for a disabled test definition, `422` for a missing or unknown field.

## Get a run

```http
GET /api/v1/runs/1842
```

`200` with the run.

### The run object

```json
{
  "id": 1842,
  "url": "https://testfleet.example.internal/runs/1842",
  "project": "customer-portal",
  "test_definition": "e2e",
  "environment": "staging",
  "trigger": "api",
  "triggered_by": "ci@example.com",
  "status": "failed",
  "final": true,
  "image": "ghcr.io/acme/portal-e2e:1.4.2",
  "image_digest": "sha256:9f2c…",
  "queued_at": "2026-10-02T09:14:03.112934Z",
  "started_at": "2026-10-02T09:14:09.870311Z",
  "finished_at": "2026-10-02T09:18:21.004512Z",
  "exit_code": 1,
  "error_message": null,
  "tests": { "passed": 41, "failed": 2, "skipped": 3 },
  "log_url": "https://testfleet.example.internal/api/v1/runs/1842/log",
  "log_truncated": false,
  "artifacts_url": "https://testfleet.example.internal/api/v1/runs/1842/artifacts"
}
```

| Field                   |                                                                                                                                                      |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `status`                | `queued`, `preparing`, `running`, `passed`, `failed`, `cancelled`, `timeout`, or `error`. See [Runs](/guides/runs/#how-the-final-status-is-decided). |
| `final`                 | `true` once the status will not change any more. Poll until it is.                                                                                   |
| `trigger`               | `manual`, `schedule`, or `api`                                                                                                                       |
| `triggered_by`          | The email of the user who started it; `null` for scheduled runs                                                                                      |
| `image`, `image_digest` | The image as configured when the run was created, and the digest it resolved to (`null` until pulled)                                                |
| `exit_code`             | The container's exit code; `null` if it never ran                                                                                                    |
| `error_message`         | TestFleet's explanation for `error`, `timeout`, and some `cancelled` runs                                                                            |
| `tests`                 | Counts from the JUnit report; `null` without one                                                                                                     |
| `log_truncated`         | `true` when the log reached the size limit and later lines were not stored                                                                           |

A pipeline should pass only on `passed`. Treat `failed` (the tests failed) differently from `error` and `timeout`, which mean TestFleet could not give a verdict.

## Cancel a run

```http
POST /api/v1/runs/1842/cancel
```

`202 Accepted` with the run. A queued run is cancelled at once. An active run's container is stopped, and the run becomes `cancelled` once it has; the response may still say `running`. Cancelling a finished run changes nothing and answers the same way.

## Get the log

```http
GET /api/v1/runs/1842/log
GET /api/v1/runs/1842/log?after=420
```

`200` with the stored, masked log as `text/plain`, one line per output line. If the stored log was truncated at the size limit, a notice says so at the end.

With `?after=<n>`, only lines after sequence number `n` are sent. Every response carries `TestFleet-Log-Sequence: <last sequence sent>`; pass it as the next `after` to print a log while the run is going, without repeats or gaps. Without new lines, the body is empty and the header repeats `after`. With `after`, the truncation notice is left out.

`410` once retention removed the log.

## List artifacts

```http
GET /api/v1/runs/1842/artifacts
```

```json
{
  "artifacts": [
    {
      "name": "playwright-report/index.html",
      "content_type": "text/html",
      "size_bytes": 81234,
      "url": "https://testfleet.example.internal/api/v1/runs/1842/artifacts/playwright-report/index.html"
    }
  ]
}
```

`410` once retention removed the artifacts.

## Download an artifact

```http
GET /api/v1/runs/1842/artifacts/playwright-report/index.html
```

The file, always as an attachment, with its content type. Single byte ranges are supported (`Range: bytes=0-1023`). `404` for a name the run does not have, `410` after retention.

```sh
curl -fsS -H "Authorization: Bearer $TESTFLEET_TOKEN" -o junit.xml \
  https://testfleet.example.internal/api/v1/runs/1842/artifacts/junit.xml
```

## Get a test definition

```http
GET /api/v1/projects/customer-portal/test-definitions/e2e
```

```json
{
  "slug": "e2e",
  "name": "E2E",
  "project": "customer-portal",
  "image": "ghcr.io/acme/portal-e2e:1.4.1",
  "enabled": true,
  "updated_at": "2026-10-01T16:40:12Z"
}
```

## Update the image

```http
PATCH /api/v1/projects/customer-portal/test-definitions/e2e
Content-Type: application/json

{"tag": "1.4.2"}
```

The body has exactly one of:

| Field   | Example                           | Effect                                                                                                                                                                        |
| ------- | --------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `tag`   | `"1.4.2"`                         | Keeps the repository and replaces the tag; drops a digest if there was one. A Docker tag: letters, digits, `_`, `.`, `-`, up to 128 characters, not starting with `.` or `-`. |
| `image` | `"ghcr.io/acme/portal-e2e:1.4.2"` | Replaces the whole reference                                                                                                                                                  |

`tag` is the usual call: a pipeline knows the version it built, not necessarily where the image lives. Other fields (name, command, limits, `enabled`) are refused with `422`; they stay in the web UI.

`200` with the updated test definition. The new image applies to runs created from then on, including scheduled ones. Runs that are already queued or running keep their image.
