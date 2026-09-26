defmodule TestFleet.Execution.Integration.StreamTest do
  # Spike step 2: stream stdout/stderr, demultiplexed and split into lines.
  use TestFleet.DockerCase, async: true

  test "lines arrive tagged by stream, with timestamps and consecutive sequence numbers" do
    {%Result{status: :passed}, lines} = run!(environment: %{"SPIKE_MODE" => "pass"})

    assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..length(lines))
    assert Enum.all?(lines, &is_integer(&1.timestamp))

    assert %{stdout: ["starting suite", "all tests passed"], stderr: ["a warning"]} =
             lines |> Enum.group_by(& &1.stream, & &1.content)
  end

  test "a chatty suite loses no lines and keeps a 40 KB line whole" do
    {result, lines} = run!(environment: %{"SPIKE_MODE" => "chatty"})

    assert result.status == :passed
    assert length(lines) == 100_001
    assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..100_001)

    {first, [long | rest]} = Enum.split(lines, 50_000)
    assert contents(first) == Enum.map(1..50_000, &"line #{&1}")
    assert long.content == String.duplicate("x", 40_000)
    assert contents(rest) == Enum.map(50_001..100_000, &"line #{&1}")
  end

  test "output without a trailing newline arrives as one line" do
    {%Result{status: :passed}, lines} = run!(environment: %{"SPIKE_MODE" => "partial"})
    assert contents(lines) == ["no newline at all"]
  end

  test "output arrives while the container is still running" do
    {request, _pid} = start_run!(environment: %{"SPIKE_MODE" => "hang"})
    await_output(request.run_id, &(&1.content == "tick 2"))

    :ok = Execution.cancel(request.run_id)
    assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)
  end
end
