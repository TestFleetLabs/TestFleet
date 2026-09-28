defmodule TestFleet.Execution.Integration.StopTest do
  # Spike steps 3 and 4: timeout and cancellation.
  use TestFleet.DockerCase, async: true

  # Durations are measured on Docker's clock (StartedAt to FinishedAt), the deadline
  # on TestFleet's. Docker Desktop's VM clock can be a few hundred ms off.
  @clock_skew 500

  describe "timeout" do
    @tag :tmp_dir
    test "a hanging suite is stopped at its deadline, and its artifacts are kept", %{
      tmp_dir: tmp_dir
    } do
      {result, lines} =
        run!(environment: %{"SPIKE_MODE" => "hang"}, timeout_seconds: 3, artifact_path: tmp_dir)

      assert result.status == :timeout
      assert "terminated" in contents(lines)
      assert_duration(result, 3_000 - @clock_skew, 3_000 + 2_000)
      assert Enum.any?(result.artifacts, &(&1.path == "summary.txt"))
    end

    test "a suite that ignores SIGTERM is killed after the grace period" do
      {result, lines} = run!(environment: %{"SPIKE_MODE" => "ignore_term"}, timeout_seconds: 3)

      assert result.status == :timeout
      refute "terminated" in contents(lines)
      # Deadline + grace period, plus a margin for Docker. Without the grace period
      # it would be about 3 s.
      assert_duration(result, 3_000 + 2_000 - @clock_skew, 3_000 + 2_000 + 3_000)
    end
  end

  describe "cancellation" do
    test "cancels a running suite" do
      {request, _pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"})
      await_output(request.run_id, &(&1.content == "tick 1"))

      assert :ok = Execution.cancel(request.run_id)
      assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)
      assert containers(request.run_id) == []
    end

    test "is idempotent, also after the run finished" do
      {request, _pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"})
      await_output(request.run_id, &(&1.content == "tick 1"))

      assert :ok = Execution.cancel(request.run_id)
      assert :ok = Execution.cancel(request.run_id)
      assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)

      assert :ok = Execution.cancel(request.run_id)
      refute_receive {:run_event, _, {:finished, _}}, 200
    end

    test "cancelling while preparing creates no container" do
      {request, _pid} = start_run!(environment: %{"SPIKE_MODE" => "pass"})
      assert :ok = Execution.cancel(request.run_id)

      assert {%Result{status: :cancelled, container_id: nil}, []} = await_finished(request.run_id)
      assert containers(request.run_id) == []
    end

    test "cancelling an unknown run is fine" do
      assert :ok = Execution.cancel(run_id())
    end
  end

  defp assert_duration(result, min_ms, max_ms) do
    duration = DateTime.diff(result.finished_at, result.started_at, :millisecond)

    assert duration >= min_ms and duration <= max_ms,
           "expected #{min_ms}..#{max_ms} ms, took #{duration} ms"
  end
end
