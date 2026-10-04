defmodule TestFleet.Execution.Integration.MaskingTest do
  # No output event ever carries a secret value.
  use TestFleet.DockerCase, async: true

  @secret "s3cret-value-42"

  test "secret values are masked wherever they appear" do
    {%Result{status: :passed}, lines} =
      run!(
        environment: %{
          "FIXTURE_MODE" => "secret",
          "FIXTURE_SECRET" => @secret,
          "FIXTURE_PLAIN" => "plain-value"
        },
        secret_keys: ["FIXTURE_SECRET"]
      )

    # stdout and stderr are separate streams; their order relative to each other is
    # not guaranteed.
    assert %{
             stdout: ["token=[MASKED] in the middle", "[MASKED]", "not secret: plain-value"],
             stderr: ["twice: [MASKED] [MASKED]"]
           } == Enum.group_by(lines, & &1.stream, & &1.content)
  end

  test "the container records the secret keys, never the values, as a label" do
    {request, _pid} =
      start_run!(
        environment: %{"FIXTURE_MODE" => "hang", "FIXTURE_SECRET" => @secret},
        secret_keys: ["FIXTURE_SECRET"]
      )

    await_output(request.run_id, &(&1.content == "tick 1"))

    {:ok, info} = Command.inspect(RunExecution.container_name(request.run_id))
    labels = info["Config"]["Labels"]
    assert labels["TestFleet.secret_keys"] == "FIXTURE_SECRET"
    refute Enum.any?(labels, fn {_key, value} -> value =~ @secret end)

    :ok = Execution.cancel(request.run_id)
    await_finished(request.run_id)
  end

  test "a reattached process masks with the values from the container" do
    {request, pid} =
      start_run!(
        image: "alpine:3",
        pull_policy: :if_missing,
        command: [
          "sh",
          "-c",
          ~S|i=0; while true; do i=$((i+1)); echo "$i $SECRET"; sleep 1; done|
        ],
        environment: %{"SECRET" => @secret},
        secret_keys: ["SECRET"]
      )

    before = await_output(request.run_id, &String.starts_with?(&1.content, "1 "))
    kill_process(pid)

    last = List.last(before)
    attach!(request.run_id, last_log_timestamp: last.timestamp, next_sequence: last.sequence + 1)
    after_attach = await_output(request.run_id, &String.starts_with?(&1.content, "3 "))

    :ok = Execution.cancel(request.run_id)
    {_result, rest} = await_finished(request.run_id)

    lines = before ++ after_attach ++ rest
    assert Enum.all?(lines, &String.ends_with?(&1.content, " [MASKED]"))
    refute Enum.any?(lines, &(&1.content =~ @secret))
  end
end
