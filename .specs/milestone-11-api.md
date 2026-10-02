# TestFleet — Milestone 11: API

## 1. Purpose

TestFleet's runs can be started by hand and by schedules. Milestone 11 adds the third way the main spec plans (sections 29 and 40): **a deployment pipeline starts the E2E suite after it deploys, and can wait for the result.**

```text
CI pipeline: build app 1.4.2 and its E2E image 1.4.2 → deploy to staging
  ↓
PATCH /api/v1/projects/customer-portal/test-definitions/e2e   {"tag": "1.4.2"}
  ↓
POST  /api/v1/projects/customer-portal/runs                    {"test_definition": "e2e", "environment": "staging"}
  ↓  201, run 1842 (queued)
GET   /api/v1/runs/1842   … until "final": true
  ↓
pass or fail the pipeline on "status"
```

Updating the test definition's image is part of the API because the E2E image is versioned with the application: when the application moves to 1.4.2, its tests do too, for this run and for every scheduled run after it.

---

## 2. Scope

### In scope

- API tokens per user: created and revoked in the settings, stored hashed, optional expiry
- Bearer token authentication for `/api/v1`
- Start a run (`trigger = api`), read it, cancel it
- Read a test definition, and update its image (a whole reference, or only the tag)
- A run's log (whole, or the lines after a sequence number) and its artifacts
- Documentation for CI: `curl` examples, a wait loop, a GitHub Actions and a GitLab CI example

### Out of scope

| What | Milestone |
|------|-----------|
| Listing and editing projects, environments, variables, schedules over the API | later |
| An image per run (overriding the test definition's for one run only) | later (section 6, "Concurrent pipelines") |
| Service accounts (tokens not owned by a person) | later; a dedicated user such as `ci@example.com` works meanwhile (section 3) |
| Token scopes (read-only, per project) | later (main spec section 36, "RBAC") |
| A CLI (main spec section 41) | later; it will use this API |
| Test results (JUnit cases) over the API | later; the run has the counts |
| An OpenAPI document | later, with the docs site |
| Rate limiting | later; the deployment is internal (Milestone 9, section 8) |
| Webhooks back to the pipeline | covered by Milestone 8's webhook channel |

---

## 3. API Tokens

A token belongs to a user and acts as that user. Every endpoint of this milestone is available to members (Milestone 10, section 5), so the role does not matter yet; admin-only areas (registries, notification channels, users) have no API.

**Format:** `tf_` followed by 32 random bytes, base64url without padding (`tf_` + 43 characters). The prefix makes tokens recognizable to secret scanners (GitHub's push protection accepts custom patterns) and to people reading a CI log.

**Storage:** `api_tokens`: `user_id`, `name`, `token_hash` (SHA-256 of the whole token, unique), `hint` (the last 4 characters, for the list), `expires_at` (nullable), `last_used_at`, timestamps. A token is high-entropy, so a fast hash is enough, and the lookup is a unique-index query on the hash. The token itself is shown once, when created, and never stored.

**Lifetime:**

- Expiry is chosen when creating: 30 days, 90 days, 1 year (preselected), or never.
- Revoking deletes the row.
- Deactivating a user deletes their tokens, like their sessions (Milestone 10, section 3). A reactivated user creates new ones.
- `last_used_at` is updated when it is older than 5 minutes, so a pipeline polling every few seconds does not write on every request.

**Who manages them:** each user their own, in the settings (section 8). Creating a token requires sudo mode, like changing the password. The Users page shows how many tokens a user has. Admins cannot see or create other users' tokens; deactivating the user is how an admin cuts one off.

**CI without a person:** until service accounts exist, an admin invites a user for the pipeline (`ci@example.com`), sets its password through the invitation link, and creates the token as that user. Then the pipeline does not break when its author leaves.

`api_tokens` are the first user-owned data. Their `Accounts` functions take the `current_scope` (`list_api_tokens(scope)`, `create_api_token(scope, attrs)`, `delete_api_token(scope, id)`), as the project's authentication rules ask for user-owned data.

---

## 4. Authentication

```http
Authorization: Bearer tf_…
```

- The `/api/v1` pipeline reads only this header: no session, no cookies, so there is no cross-site request forgery to defend against, and a logged-in browser cannot call the API by accident.
- A missing, unknown, or expired token, or one whose user is deactivated: `401` with `WWW-Authenticate: Bearer` and the error body of section 5. The message does not say which of these it was.
- The plug assigns `current_scope` (`TestFleet.Accounts.Scope` for the token's user) and `api_token`, so controllers look like the rest of the application.
- The `Authorization` header is never logged. Phoenix does not log request headers; the plug adds nothing that would.

---

## 5. Conventions

- **Base path `/api/v1`.** **Deviation:** the main spec (section 40) wrote `/api/…`. The API is called from pipelines that outlive TestFleet versions; a version in the path lets a later incompatible change live next to the old one. The main spec is updated.
- **Addressing by slug.** Projects, test definitions, and environments are named by their slugs, as in the web UI's URLs; runs by their id.
- **JSON** request and response bodies, except the log (plain text) and artifact files (their own type).
- **Times** in ISO 8601, UTC, with microseconds where the database has them.
- **Unknown fields** in a request body are refused (`422`), so a typo like `"enviroment"` fails loudly instead of being ignored.

**Errors:**

```json
{"error": {"code": "not_found", "message": "No environment \"stagign\" in project \"customer-portal\"."}}
```

| Status | `code` | When |
|--------|--------|------|
| 400 | `bad_request` | The body is not JSON, or not an object |
| 401 | `unauthorized` | Section 4 |
| 404 | `not_found` | Unknown project, test definition, environment, run, or artifact; the message names which |
| 409 | `test_definition_disabled` | Starting a run of a disabled test definition |
| 410 | `expired` | The log or the artifacts of a run were removed by retention (Milestone 6, section 8) |
| 422 | `invalid` | Validation failed; `"details": {"field": ["message", …]}` |

---

## 6. Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/api/v1/projects/:project/runs` | Start a run |
| `GET` | `/api/v1/runs/:id` | A run's status and result |
| `POST` | `/api/v1/runs/:id/cancel` | Cancel a run |
| `GET` | `/api/v1/runs/:id/log` | The run's log, as text |
| `GET` | `/api/v1/runs/:id/artifacts` | The run's artifacts, as a list |
| `GET` | `/api/v1/runs/:id/artifacts/*name` | One artifact's file |
| `GET` | `/api/v1/projects/:project/test-definitions/:slug` | A test definition |
| `PATCH` | `/api/v1/projects/:project/test-definitions/:slug` | Update its image |

### Start a run

```http
POST /api/v1/projects/customer-portal/runs
{"test_definition": "e2e", "environment": "staging"}
```

`201 Created`, with `Location: /api/v1/runs/1842` and the run (below). The run is `queued`; it goes through the dispatcher like every other run (main spec section 29). `trigger` is `api`, `triggered_by_user_id` the token's user, and `api_token_id` the token (section 9), so the run page can say which pipeline started it.

`Runs.create_manual_run/3` becomes `Runs.create_run/3` with the trigger, user, and token as options; manual and API runs share it, including the checks that the definition is enabled and the environment belongs to its project.

### A run

```json
{
  "id": 1842,
  "url": "https://testfleet.example.com/runs/1842",
  "project": "customer-portal",
  "test_definition": "e2e",
  "environment": "staging",
  "trigger": "api",
  "triggered_by": "ci@example.com",
  "status": "failed",
  "final": true,
  "image": "ghcr.io/acme/portal-e2e:1.4.2",
  "image_digest": "sha256:…",
  "queued_at": "…", "started_at": "…", "finished_at": "…",
  "exit_code": 1,
  "error_message": null,
  "tests": {"passed": 41, "failed": 2, "skipped": 3},
  "log_url": "https://…/api/v1/runs/1842/log",
  "artifacts_url": "https://…/api/v1/runs/1842/artifacts"
}
```

`final` saves every client the list of final statuses. `tests` is `null` without a JUnit report. `status` is one of the main spec's (section 8); a pipeline should pass only on `passed`, and treat `failed` (the tests failed) differently from `error` and `timeout` (TestFleet could not tell).

### Cancel

`POST /api/v1/runs/:id/cancel`: `202 Accepted` with the run. Idempotent: cancelling a finished run changes nothing and answers the same way. An active run reaches `cancelled` when its container has stopped (main spec section 26), so the response may still say `running`.

### Log

`GET /api/v1/runs/:id/log`: the stored, masked log as `text/plain`, streamed like the download in the web UI (Milestone 4, section 8), with the same truncation notice.

`?after=<sequence>` returns only the lines after that sequence number. Every response carries `TestFleet-Log-Sequence: <last sequence sent>`, so a pipeline can print the log while it waits, without fetching it again from the start.

### Artifacts

`GET /api/v1/runs/:id/artifacts`:

```json
{"artifacts": [{"name": "report/index.html", "content_type": "text/html", "size_bytes": 81234,
                "url": "https://…/api/v1/runs/1842/artifacts/report/index.html"}]}
```

`GET /api/v1/runs/:id/artifacts/*name` sends the file with the same headers and range support as the web UI (Milestone 6, section 7), always as an attachment. The response code and headers are shared with `TestFleetWeb.ArtifactController` through one module, so the two cannot drift apart.

### Test definition

`GET /api/v1/projects/:project/test-definitions/:slug`:

```json
{"slug": "e2e", "name": "E2E", "project": "customer-portal", "image": "ghcr.io/acme/portal-e2e:1.4.1",
 "enabled": true, "updated_at": "…"}
```

`PATCH` takes exactly one of:

| Field | Example | Effect |
|-------|---------|--------|
| `image` | `"ghcr.io/acme/portal-e2e:1.4.2"` | Replaces the whole reference, validated like the form (`ImageRef.parse/1`) |
| `tag` | `"1.4.2"` | Keeps the repository and replaces the tag (and drops a digest). Validated as a Docker tag: `[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}` |

`tag` is the usual call: a pipeline knows the version it built, not necessarily where the image lives. Any other field (name, command, limits, `enabled`) is refused with `422`; those stay in the web UI.

`200` with the updated test definition. The change goes through `TestDefinitions.update_test_definition/2`, so the validation is the form's. It applies to runs created from then on: queued and running runs already copied their image (main spec section 7). The test definition's page shows the new image like any edit.

**Concurrent pipelines.** Two pipelines that each update the image and then start a run can interleave, and one of them would test the other's image. The run's response names the image it uses, so the pipeline can check it. Pipelines that deploy the same environment should not run concurrently anyway (GitHub's `concurrency`, GitLab's `resource_group`); the CI documentation says so. An image per run, which removes the race, is a later addition (section 2).

---

## 7. Router

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug TestFleetWeb.APIAuth
end

# The log and artifact files are not JSON, and are fetched by curl without an Accept header.
pipeline :api_files do
  plug TestFleetWeb.APIAuth
end

scope "/api/v1", TestFleetWeb.API do
  pipe_through :api
  # runs, cancel, artifact list, test definitions
end

scope "/api/v1", TestFleetWeb.API do
  pipe_through :api_files
  # log, artifact files
end
```

The access test of Milestone 10 (it walks every route) learns a third kind of route: `/api/v1/*` answers `401` without a token, and also without a token while a browser session exists.

Controllers live in `TestFleetWeb.API` with a fallback controller that turns `{:error, …}` into section 5's errors, and JSON modules (`RunJSON`, `TestDefinitionJSON`, `ErrorJSON`). Absolute URLs in responses come from the endpoint's configured URL (`PHX_HOST`), like the links in notifications (Milestone 8).

---

## 8. UI

- **Settings, "API tokens" panel:** the user's tokens with name, hint (`tf_…a1B2`), created, expires, last used; "New token" (name, expiry; sudo mode) shows the token once, with a copy button and the note that it will not be shown again; "Revoke" with confirmation.
- **Run page:** API runs show "by `<email>` via `<token name>`", or "via a revoked token". The runs list shows the email, as for manual runs.
- **Users page:** the number of tokens per user.

---

## 9. Data Model Changes

| Change | Purpose |
|--------|---------|
| `api_tokens`: `user_id` (`on_delete: :delete_all`), `name`, `token_hash` (unique), `hint`, `expires_at`, `last_used_at`, timestamps; index on `user_id` | Section 3 |
| `runs.api_token_id`, nullable, `on_delete: :nilify_all` | Which token started an API run (sections 6, 8) |

`runs.trigger` already allows `api`; `runs.triggered_by_user_id` exists (Milestone 10).

---

## 10. Documentation

`deploy/README.md` gains "Starting runs from CI":

- creating a token (and the dedicated CI user of section 3)
- the `curl` calls of section 1, and a wait loop that prints the log with `?after=` and exits non-zero unless the run passed, in POSIX shell and in PowerShell
- a GitHub Actions job and a GitLab CI job, both with the token as a masked secret and a concurrency guard (section 6)
- the endpoint reference of section 6

The reference moves to the docs site once it exists.

---

## 11. Slices

| # | Slice | Depends on |
|---|-------|-----------|
| A | Tokens: table, `Accounts` functions with scope, settings panel, deactivation deletes them, the `APIAuth` plug. Runs: start, read, cancel; `Runs.create_run/3`; `runs.api_token_id`; the run page's "via". | – |
| B | Test definitions: read, `PATCH` with `image` or `tag`. | A |
| C | Log (`?after=`) and artifacts over the API; the shared artifact response; the CI documentation. | A |

Each slice passes `mix precommit` on its own.

**Status (2026-10-02):** slice A is built (704 tests).

Notes from slice A:

- Files: `TestFleetWeb.APIAuth` (`lib/testfleet_web/api_auth.ex`); controllers, JSON, the fallback controller, and the body helper in `lib/testfleet_web/controllers/api/`. Routes: `POST /api/v1/projects/:project/runs`, `GET /api/v1/runs/:id`, `POST /api/v1/runs/:id/cancel`.
- The token's name is shown by its run (the run preloads only the token's `id` and `name`, because runs are broadcast). A revoked token's runs keep their user and lose the token (`on_delete: :nilify_all`).
- A body sent as a form (`curl -d` without `Content-Type: application/json`) is refused with a `400` that says so, instead of the confusing "unknown field" of a form-parsed JSON string.
- Errors raised before the router, like a malformed JSON body, are rendered by `ErrorJSON` in the API's format. `render_errors` lists JSON first, so clients that accept `*/*` (curl) get JSON; browsers ask for `text/html` and still get HTML.
- The Users page shows the number of tokens in the "Login" column. The copy button of the invitation link became a shared component (`copy_field`), used for the new token too.
- Fixed on the way: the first-run setup token was generated lazily, so two concurrent first calls could each store their own token (a flaky OIDC setup test). The application now generates it when it starts.

---

## 12. Tests

- **Tokens:** shown once, stored only as a hash; listed with the hint; revoked tokens, expired tokens, and tokens of deactivated users are refused; deactivation deletes them; one user cannot list or revoke another's; creating needs sudo mode; `last_used_at` is throttled.
- **Authentication:** every `/api/v1` route answers `401` without a token, with a malformed header, and with only a browser session (the router walk); the `WWW-Authenticate` header.
- **Runs:** starting creates a queued `api` run with the user and token and is broadcast; unknown project, test definition, and environment are `404` naming which; an environment of another project is `404`; a disabled definition is `409`; unknown body fields are `422`; reading a run; `final` for each status; cancelling queued, active, and finished runs.
- **Test definitions:** `image` and `tag` update the reference (with a registry host and port, a Docker Hub short name, a digest); an invalid image or tag, both fields, neither, or another field are `422`; the new image applies to the next run, not to a queued one.
- **Log:** the whole log; `?after=`; the sequence header; truncation notice; `410` after retention.
- **Artifacts:** the list; a file with its content type and the sandbox header; a range; an unknown name; `410` after retention.

---

## 13. Done

Milestone 11 is done when all slices pass `mix precommit`, the Docker tests still pass, and a manual walkthrough works:

1. A member creates a token in the settings; it is shown once.
2. With `curl`: the image tag of a test definition is updated, a run is started, and the wait loop prints the log while the run executes and exits with the run's result.
3. The run page shows "Started by … via …"; the test definition shows the new image; the next scheduled run uses it.
4. A failing suite makes the loop exit non-zero; cancelling through the API ends the run as `cancelled`.
5. The token is revoked, and the next call is `401`.
6. The GitHub Actions example from the documentation runs once against a TestFleet the runner can reach.
