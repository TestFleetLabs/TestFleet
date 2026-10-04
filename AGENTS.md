# TestFleet

TestFleet is a self-hosted Phoenix application that schedules, executes, and monitors containerized E2E test suites. Tests belong to the application; test execution belongs to TestFleet. TestFleet is framework-agnostic and must never become an E2E testing framework itself.

## Sources of truth

- **Architecture and behaviour:** [.specs/tech-architecture-execution-spec.md](.specs/tech-architecture-execution-spec.md). Read the relevant sections before implementing a feature, and follow the spec's naming (contexts, tables, fields, statuses, events). If an implementation needs to deviate from the spec, say so and update the spec in the same change.
- **Elixir, Phoenix, LiveView, Ecto, HEEx, and test conventions:** [.claude/rules/elixir-phoenix.md](.claude/rules/elixir-phoenix.md). These rules apply to all code in this repository.

## Workflow

- Run `mix precommit` when you are done with all changes and fix any pending issues.
- **Never commit or push.** Leave all changes uncommitted: the maintainer reviews them and commits themselves. When a change is done, provide a commit message in the reply instead (a short subject line in the imperative, a blank line, then a body that explains what changed and why).
- Use `Req` for all HTTP, including the Docker Engine API. Do not add `:httpoison`, `:tesla`, or use `:httpc`.
- Generate migrations with `mix ecto.gen.migration name_using_underscores`.
- Local services run through `docker compose up -d`: PostgreSQL and a Docker socket proxy on `tcp://localhost:2375` (use it as `DOCKER_HOST`).

## Architecture rules to keep in mind

- **Contexts:** `TestFleet.Projects`, `Environments`, `TestDefinitions`, `Registries`, `Schedules`, `Runs`, `Results`, `Artifacts`, `Execution`, `Notifications`, `Accounts`. Keep `TestFleet.Execution` isolated from the UI and from test configuration.
- **Execution is not an Oban job.** Oban creates runs (schedule tick) and does fire-and-forget work (cleanup, notifications). `Execution.Dispatcher` admits queued runs under the global and per-environment limits; one `RunExecution` process (`restart: :temporary`) per run owns the container lifecycle.
- **One pipeline.** Manual, scheduled, and API runs all create a `queued` run and go through the dispatcher. They differ only in `runs.trigger`.
- **Docker Engine HTTP API, not the CLI.** All Docker calls go through `TestFleet.Execution.Docker.Command`. Registry auth is per pull via `X-Registry-Auth`; never `docker login`. Containers use `Tty: false`, no `AutoRemove`, the deterministic name `TestFleet-run-<id>`, `TestFleet=*` labels, the `TestFleet-runs` network, `no-new-privileges`, and all capabilities dropped.
- **PostgreSQL is the source of truth; PubSub is only transport.** Logs are masked, batched (100 ms, 500 lines, or 1 MiB), persisted, then broadcast on `run:<id>`.
- **Recovery is the reconciler's job.** `try/after` cleanup is best effort. Deadlines derive from the persisted `started_at`, never from a fresh timer.
- **Final status** follows the decision table in spec section 23 (`Execution.Status`). Keep `failed` (tests failed) distinct from `error` (infrastructure failed).
- **Secrets:** environment variable values, registry passwords, and notification URLs and signing secrets are encrypted at rest, never returned to the browser, and masked in logs. The `TestFleet_` env var prefix is reserved.
- **No automatic retries** of runs (`max_attempts: 1` for Oban workers that create runs).

<!-- phoenix-gen-auth-start -->
## Authentication

- **Always** handle authentication flow at the router level with proper redirects
- **Always** be mindful of where to place routes. `phx.gen.auth` creates multiple router plugs and `live_session` scopes:
  - A plug `:fetch_current_scope_for_user` that is included in the default browser pipeline
  - A plug `:require_authenticated_user` that redirects to the log in page when the user is not authenticated
  - A `live_session :current_user` scope - for routes that need the current user but don't require authentication, similar to `:fetch_current_scope_for_user`
  - A `live_session :require_authenticated_user` scope - for routes that require authentication, similar to the plug with the same name
  - In both cases, a `@current_scope` is assigned to the Plug connection and LiveView socket
  - A plug `redirect_if_user_is_authenticated` that redirects to a default path in case the user is authenticated - useful for a registration page that should only be shown to unauthenticated users
- **Always let the user know in which router scopes, `live_session`, and pipeline you are placing the route, AND SAY WHY**
- `phx.gen.auth` assigns the `current_scope` assign - it **does not assign a `current_user` assign**
- Organizations are the tenants (spec section 35). The scope carries the user, the organization, and the membership. Context functions that find, list, or create roots (projects, registries, channels, runs, API tokens, dashboard figures) take the scope first; functions on children take their parent found through the scope (`Environments.get_environment!(project, slug)`). Never build a struct from an id in the request (`%Project{id: params["id"]}`): look it up through the scope. Internal unscoped functions (`Runs.get_run!/1`) are for background processes only. LiveViews subscribe to their organization's topics (`Runs.subscribe(scope)`). Roles are enforced at the edge with `TestFleet.Accounts.Scope.admin?/1` and the `:require_admin` `live_session`.
- **Organization pages live under `scope "/:org"`** at the end of the router: in `live_session :organization` (members) or `live_session :require_admin`, whose `on_mount` hooks (and the `:fetch_organization` plug for controllers) put the organization into the scope and assign `@organization`, or answer 404 to non-members. Build their paths as `~p"/#{@organization}/projects"` (`Organization` derives `Phoenix.Param` on its slug); in code, `socket.assigns.organization`. Only personal pages (`/users/settings`, `/organizations`) and the open pages stay outside, in `live_session :require_authenticated_user` or `:current_user`. A new top-level path segment must be added to `Organization.reserved_slugs/0`.
- The API (`/api/v1`, spec section 38) authenticates with a bearer token through `TestFleetWeb.APIAuth` in the `:api` and `:api_files` pipelines, never with the session. It assigns `current_scope` and `api_token`. New API routes go into the existing `scope "/api/v1"` blocks (`:api_files` for responses that are not JSON); the access test checks that every one of them requires a token.
- To derive/access `current_user` in templates, **always use the `@current_scope.user`**, never use **`@current_user`** in templates or LiveViews
- **Never** duplicate `live_session` names. A `live_session :current_user` can only be defined __once__ in the router, so all routes for the `live_session :current_user`  must be grouped in a single block
- Anytime you hit `current_scope` errors or the logged in session isn't displaying the right content, **always double check the router and ensure you are using the correct plug and `live_session` as described below**

### Routes that require authentication

LiveViews that require login should **always be placed inside the __existing__ `live_session :require_authenticated_user` block**:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :require_authenticated_user,
        on_mount: [{TestFleetWeb.UserAuth, :require_authenticated}] do
        # phx.gen.auth generated routes
        live "/users/settings", UserLive.Settings, :edit
        live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
        # our own routes that require logged in user
        live "/", MyLiveThatRequiresAuth, :index
      end
    end

Controller routes must be placed in a scope that sets the `:require_authenticated_user` plug:

    scope "/", AppWeb do
      pipe_through [:browser, :require_authenticated_user]

      get "/", MyControllerThatRequiresAuth, :index
    end

### Routes that work with or without authentication

LiveViews that can work with or without authentication, **always use the __existing__ `:current_user` scope**, ie:

    scope "/", MyAppWeb do
      pipe_through [:browser]

      live_session :current_user,
        on_mount: [{TestFleetWeb.UserAuth, :mount_current_scope}] do
        # our own routes that work with or without authentication
        live "/", PublicLive
      end
    end

Controllers automatically have the `current_scope` available if they use the `:browser` pipeline.

<!-- phoenix-gen-auth-end -->
