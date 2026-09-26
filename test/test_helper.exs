# Tests tagged :docker need the Docker socket proxy and the fixture images:
# mix test --only docker (see .specs/execution-spike-spec.md, section 9)
ExUnit.start(exclude: [:docker])
Ecto.Adapters.SQL.Sandbox.mode(TestFleet.Repo, :manual)
