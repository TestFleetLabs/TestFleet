defmodule TestFleet.Execution.Integration.UnreachableTest do
  # A Docker Engine that cannot be reached is an infrastructure error.
  # Not async: it changes the global Docker endpoint.
  use TestFleet.DockerCase, async: false

  setup do
    config = Application.fetch_env!(:testfleet, TestFleet.Execution.Docker)
    Application.put_env(:testfleet, TestFleet.Execution.Docker, host: "tcp://127.0.0.1:1")
    on_exit(fn -> Application.put_env(:testfleet, TestFleet.Execution.Docker, config) end)
  end

  test "the run finishes as an error instead of crashing" do
    {result, _} = run!(environment: %{"FIXTURE_MODE" => "pass"})

    assert result.status == :error
    assert result.error_message =~ "Docker Engine unreachable"
  end
end
