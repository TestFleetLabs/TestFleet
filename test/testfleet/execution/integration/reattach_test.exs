defmodule TestFleet.Execution.Integration.ReattachTest do
  # Spike step 7: resume a run after its process died.
  #
  # These tests sleep on purpose: the point is that the container keeps working in
  # real time while no process is attached.
  use TestFleet.DockerCase, async: true

  test "resumes the log stream without gaps or duplicates" do
    {request, pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"})
    before = await_output(request.run_id, &(&1.content == "tick 2"))
    kill_process(pid)

    assert [%{"State" => "running"}] = containers(request.run_id)
    Process.sleep(2_000)

    last = List.last(before)
    attach!(request.run_id, last_log_timestamp: last.timestamp, next_sequence: last.sequence + 1)
    after_attach = await_output(request.run_id, &(&1.content == "tick 6"))

    :ok = Execution.cancel(request.run_id)
    {%Result{status: :cancelled}, rest} = await_finished(request.run_id)

    lines = before ++ after_attach ++ rest
    ticks = lines |> contents() |> Enum.filter(&String.starts_with?(&1, "tick "))

    assert ticks == Enum.map(1..length(ticks), &"tick #{&1}")
    assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..length(lines))
  end

  test "the original deadline survives the reattach" do
    {request, pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"}, timeout_seconds: 5)
    before = await_output(request.run_id, &(&1.content == "tick 2"))
    kill_process(pid)
    Process.sleep(1_000)

    last = List.last(before)
    attach!(request.run_id, last_log_timestamp: last.timestamp, next_sequence: last.sequence + 1)
    {result, _} = await_finished(request.run_id)

    assert result.status == :timeout
    duration = DateTime.diff(result.finished_at, result.started_at, :millisecond)
    assert duration >= 5_000 and duration <= 5_000 + 2_000, "took #{duration} ms"
  end

  test "reattaching after the deadline stops the container right away" do
    {request, pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"}, timeout_seconds: 2)
    await_output(request.run_id, &(&1.content == "tick 1"))
    kill_process(pid)
    Process.sleep(2_500)

    attach!(request.run_id, [])
    assert {%Result{status: :timeout}, _} = await_finished(request.run_id, 5_000)
    assert containers(request.run_id) == []
  end

  test "finishes a container that exited while nothing was attached" do
    {request, pid} =
      start_run!(
        image: "alpine:3",
        pull_policy: :if_missing,
        command: ["sh", "-c", "echo before; sleep 2; echo after; exit 3"]
      )

    # Under load, "after" can arrive in the same batch; the reattach replays it.
    before =
      request.run_id
      |> await_output(&(&1.content == "before"))
      |> Enum.find(&(&1.content == "before"))

    kill_process(pid)
    Process.sleep(3_000)

    attach!(request.run_id, last_log_timestamp: before.timestamp, next_sequence: 2)
    {result, lines} = await_finished(request.run_id)

    assert result.status == :failed
    assert result.exit_code == 3
    assert [%{content: "after", sequence: 2}] = lines
    assert containers(request.run_id) == []
  end

  test "a container removed while nothing was attached is an error" do
    {request, pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"})
    await_output(request.run_id, &(&1.content == "tick 1"))
    kill_process(pid)
    :ok = Command.remove(RunExecution.container_name(request.run_id))

    attach!(request.run_id, [])

    assert {%Result{status: :error, error_message: "container disappeared"}, _} =
             await_finished(request.run_id)
  end
end
