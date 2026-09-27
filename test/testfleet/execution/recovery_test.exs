defmodule TestFleet.Execution.RecoveryTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Recovery
  alias TestFleet.Runs.Run

  defp container(run_id), do: %{run_id: run_id, container_id: "container-#{run_id}"}

  test "attaches to active runs that still have a container" do
    preparing = %Run{id: 1, status: :preparing}
    running = %Run{id: 2, status: :running}

    assert Recovery.plan([preparing, running], [], [container(1), container(2)]) ==
             [{:attach, preparing}, {:attach, running}]
  end

  test "fails active runs without a container" do
    runs = [%Run{id: 1, status: :preparing}, %Run{id: 2, status: :running}]

    assert [{:fail, 1, "TestFleet restarted while preparing the run"}, {:fail, 2, message}] =
             Recovery.plan(runs, [], [])

    assert message == "container disappeared"
  end

  test "removes the containers of finished runs" do
    assert Recovery.plan([], [3], [container(3)]) == [{:remove, 3, "container-3"}]
  end

  test "leaves containers without a run row alone" do
    assert Recovery.plan([], [], [container(4)]) == []
  end
end
