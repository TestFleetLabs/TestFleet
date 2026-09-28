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

  describe "rule 5a: interrupted by Docker" do
    @interrupted %{started: true, interrupted: true}

    test "a non-zero exit code is an error, whatever JUnit says" do
      message = "Docker was interrupted while the suite was running (exit code 143)"

      assert Status.decide(Map.put(@interrupted, :exit_code, 143)) == {:error, message}

      assert Status.decide(Map.merge(@interrupted, %{exit_code: 143, junit: %{failed: 2}})) ==
               {:error, message}
    end

    test "a suite that exited 0 passed all the same" do
      assert Status.decide(Map.put(@interrupted, :exit_code, 0)) == {:passed, nil}
    end

    test "cancel, timeout, OOM, and a missing container win" do
      facts = Map.put(@interrupted, :exit_code, 137)

      assert Status.decide(Map.put(facts, :cancelled, true)) == {:cancelled, nil}
      assert Status.decide(Map.put(facts, :timed_out, true)) == {:timeout, nil}
      assert Status.decide(Map.put(facts, :oom_killed, true)) == {:error, "memory limit exceeded"}

      assert Status.decide(Map.put(@interrupted, :container_missing, true)) ==
               {:error, "container disappeared"}
    end
  end

  describe "JUnit" do
    defp with_junit(exit_code, failed),
      do: Map.merge(@started, %{exit_code: exit_code, junit: %{failed: failed}})

    test "rule 6: exit code 0 with failures is failed" do
      assert Status.decide(with_junit(0, 2)) == {:failed, nil}
      assert Status.decide(with_junit(0, 0)) == {:passed, nil}
    end

    test "rule 8: a non-zero exit code with failures is failed" do
      assert Status.decide(with_junit(1, 1)) == {:failed, nil}
    end

    test "rule 9: a non-zero exit code without failures is an error" do
      assert Status.decide(with_junit(3, 0)) ==
               {:error, "The suite exited with code 3, but its JUnit report has no failures"}
    end

    test "rule 10: a non-zero exit code without JUnit stays failed" do
      assert Status.decide(Map.merge(@started, %{exit_code: 1, junit: nil})) == {:failed, nil}
    end

    test "cancellation, timeout, and OOM win over JUnit" do
      assert Status.decide(Map.put(with_junit(0, 0), :cancelled, true)) == {:cancelled, nil}
      assert Status.decide(Map.put(with_junit(143, 3), :timed_out, true)) == {:timeout, nil}

      assert Status.decide(Map.put(with_junit(137, 0), :oom_killed, true)) ==
               {:error, "memory limit exceeded"}
    end
  end
end
