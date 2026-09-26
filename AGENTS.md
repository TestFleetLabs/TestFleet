# TestFleet

TestFleet is a self-hosted Phoenix application that schedules, executes, and monitors containerized E2E test suites. Tests belong to the application; test execution belongs to TestFleet. TestFleet is framework-agnostic and must never become an E2E testing framework itself.

## Sources of truth

- **Architecture and behaviour:** [.specs/tech-architecture-execution-spec.md](.specs/tech-architecture-execution-spec.md). Read the relevant sections before implementing a feature, and follow the spec's naming (contexts, tables, fields, statuses, events). If an implementation needs to deviate from the spec, say so and update the spec in the same change.
- **Elixir, Phoenix, LiveView, Ecto, HEEx, and test conventions:** [.claude/rules/elixir-phoenix.md](.claude/rules/elixir-phoenix.md). These rules apply to all code in this repository.

## Workflow

- Run `mix precommit` when you are done with all changes and fix any pending issues.
- Use `Req` for all HTTP, including the Docker Engine API. Do not add `:httpoison`, `:tesla`, or use `:httpc`.
- Generate migrations with `mix ecto.gen.migration name_using_underscores`.
- Local services run through `docker compose up -d`: PostgreSQL and a Docker socket proxy on `tcp://localhost:2375` (use it as `DOCKER_HOST`).

## Architecture rules to keep in mind

- **Contexts:** `TestFleet.Projects`, `Environments`, `TestDefinitions`, `Schedules`, `Runs`, `Results`, `Artifacts`, `Execution`, `Notifications`, `Accounts`. Keep `TestFleet.Execution` isolated from the UI and from test configuration.
- **Execution is not an Oban job.** Oban creates runs (schedule tick) and does fire-and-forget work (cleanup, notifications). `Execution.Dispatcher` admits queued runs under the global and per-environment limits; one `RunExecution` process (`restart: :temporary`) per run owns the container lifecycle.
- **One pipeline.** Manual, scheduled, and API runs all create a `queued` run and go through the dispatcher. They differ only in `runs.trigger`.
- **Docker Engine HTTP API, not the CLI.** All Docker calls go through `TestFleet.Execution.Docker.Command`. Registry auth is per pull via `X-Registry-Auth`; never `docker login`. Containers use `Tty: false`, no `AutoRemove`, the deterministic name `TestFleet-run-<id>`, `TestFleet=*` labels, the `TestFleet-runs` network, `no-new-privileges`, and all capabilities dropped.
- **PostgreSQL is the source of truth; PubSub is only transport.** Logs are masked, batched (100 ms or 500 lines), persisted, then broadcast on `run:<id>`.
- **Recovery is the reconciler's job.** `try/after` cleanup is best effort. Deadlines derive from the persisted `started_at`, never from a fresh timer.
- **Final status** follows the decision table in spec section 24. Keep `failed` (tests failed) distinct from `error` (infrastructure failed).
- **Secrets:** environment variable values and registry passwords are encrypted at rest, never returned to the browser, and masked in logs. The `TestFleet_` env var prefix is reserved.
- **No automatic retries** of runs (`max_attempts: 1` for Oban workers that create runs).
