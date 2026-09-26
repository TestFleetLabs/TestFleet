defmodule TestFleet.Execution.StatusTest do
  use ExUnit.Case, async: true

  alias TestFleet.Execution.Status

  @started %{started: true}

  test "exit code 0 passes, any other exit code fails" do
    assert Status.decide(Map.put(@started, :exit_code, 0)) == {:passed, nil}
    assert Status.decide(Map.put(@started, :exit_code, 1)) == {:failed, nil}
    assert Status.decide(Map.put(@started, :exit_code, 137)) == {:failed, nil}
  end

  test "failures before the container started are errors" do
    assert Status.decide(%{started: false, error: "manifest unknown"}) ==
             {:error, "manifest unknown"}

    assert Status.decide(%{started: false}) == {:error, "container did not start"}
  end

  test "OOM and a missing container are errors, whatever the exit code" do
    assert Status.decide(Map.merge(@started, %{oom_killed: true, exit_code: 137})) ==
             {:error, "memory limit exceeded"}

    assert Status.decide(Map.merge(@started, %{container_missing: true})) ==
             {:error, "container disappeared"}
  end

  test "an unknown exit code is an error" do
    assert Status.decide(Map.put(@started, :error, "lost the wait stream")) ==
             {:error, "lost the wait stream"}
  end

  test "cancelled beats everything, timeout beats everything else" do
    everything = %{started: true, oom_killed: true, container_missing: true, exit_code: 137}

    assert Status.decide(Map.merge(everything, %{cancelled: true, timed_out: true})) ==
             {:cancelled, nil}

    assert Status.decide(Map.put(everything, :timed_out, true)) == {:timeout, nil}
  end

  test "a run cancelled before it started is cancelled, not an error" do
    assert Status.decide(%{cancelled: true, started: false}) == {:cancelled, nil}
  end
end
