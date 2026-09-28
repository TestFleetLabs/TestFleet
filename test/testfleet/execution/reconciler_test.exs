defmodule TestFleet.Execution.ReconcilerTest do
  # The rules of Milestone 7, section 4, without Docker or a database.
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Reconciler
  alias TestFleet.Runs.Run

  @instance "11111111-1111-1111-1111-111111111111"
  @now ~U[2026-09-28 12:00:00.000000Z]

  defp run(id, status, fields \\ []),
    do: struct!(%Run{id: id, status: status, updated_at: @now}, fields)

  defp container(run_id, fields \\ []) do
    Enum.into(fields, %{
      run_id: run_id,
      container_id: "container-#{run_id}",
      instance: @instance,
      state: "running",
      stop_grace_seconds: 30
    })
  end

  defp plan(fields, mode \\ :periodic) do
    input =
      Enum.into(fields, %{
        instance: @instance,
        now: @now,
        active_runs: [],
        containers: [],
        executing: MapSet.new(),
        existing_run_ids: MapSet.new(),
        final_run_ids: MapSet.new()
      })

    input = %{
      input
      | executing: MapSet.new(input.executing),
        existing_run_ids:
          MapSet.new(Enum.to_list(input.existing_run_ids) ++ Enum.map(input.active_runs, & &1.id)),
        final_run_ids: MapSet.new(input.final_run_ids)
    }

    Reconciler.plan(input, mode)
  end

  describe "active runs" do
    test "1: a run with a process is left to it, but a requested cancel is sent again" do
      owned = run(1, :running)
      cancelling = run(2, :running, cancel_requested_at: @now)

      assert plan(
               active_runs: [owned, cancelling],
               containers: [container(1), container(2)],
               executing: [1, 2]
             ) == [{:cancel, 2}]
    end

    test "2 and 3: a run without a process is attached to its container" do
      running = run(1, :running)
      preparing = run(2, :preparing)
      cancelling = run(3, :running, cancel_requested_at: @now)

      assert plan(
               active_runs: [running, preparing, cancelling],
               containers: [container(1), container(2), container(3, state: "exited")]
             ) == [
               {:attach, running, false},
               {:attach, preparing, false},
               {:attach, cancelling, true}
             ]
    end

    test "4: a cancelled run without a container is finalized as cancelled" do
      assert plan(active_runs: [run(1, :preparing, cancel_requested_at: @now)]) ==
               [{:mark_cancelled, 1}]
    end

    test "5: a preparing run without process and container is lost after 60 s" do
      fresh = run(1, :preparing, updated_at: DateTime.add(@now, -59, :second))
      old = run(2, :preparing, updated_at: DateTime.add(@now, -60, :second))

      assert plan(active_runs: [fresh, old]) ==
               [{:fail, 2, "TestFleet lost the run while preparing it"}]
    end

    test "5: at startup no process can exist, so there is no grace" do
      fresh = run(1, :preparing)

      assert plan([active_runs: [fresh]], :startup) ==
               [{:fail, 1, "TestFleet lost the run while preparing it"}]
    end

    test "6: a running run without a container disappeared" do
      assert plan(active_runs: [run(1, :running)]) == [{:fail, 1, "container disappeared"}]
    end
  end

  describe "containers" do
    test "7: the container of a finished run is removed, unless its process still ends" do
      assert plan(
               containers: [container(1), container(2)],
               existing_run_ids: [1, 2],
               final_run_ids: [1, 2],
               executing: [2]
             ) == [{:remove, 1, "container-1"}]
    end

    test "8: a container of this instance without a run row is an orphan" do
      orphan = container(9, state: "running", stop_grace_seconds: 5)
      assert plan(containers: [orphan]) == [{:remove_orphan, orphan}]
    end

    test "legacy containers without an instance label are matched, never orphans" do
      legacy_run = run(1, :running)
      legacy = container(1, instance: nil)

      assert plan(active_runs: [legacy_run], containers: [legacy, container(2, instance: nil)]) ==
               [{:attach, legacy_run, false}]
    end

    test "the container of a queued run is left alone" do
      assert plan(containers: [container(1)], existing_run_ids: [1]) == []
    end
  end
end
