# Tests tagged :docker need the Docker socket proxy and the fixture images:
# mix test --only docker (see .specs/execution-spike-spec.md, section 9)
ExUnit.start(exclude: [:docker])

# Run ids of the test database start at 10^9, so its containers (TestFleet-run-<id>)
# cannot collide with those of the dev database on the same Docker host. Sequences
# are not rolled back with the sandbox, so ids keep growing across test runs.
TestFleet.Repo.query!(
  "SELECT setval('runs_id_seq', GREATEST((SELECT last_value FROM runs_id_seq), 1000000000))"
)

Ecto.Adapters.SQL.Sandbox.mode(TestFleet.Repo, :manual)
