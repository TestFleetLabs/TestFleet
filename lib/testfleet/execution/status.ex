defmodule TestFleet.Execution.Status do
  @moduledoc """
  Decides the final status of a run (main spec section 24).

  The first matching rule wins. `junit` is the summary of the run's JUnit files, or
  `nil` without any (Milestone 6, section 5); `failed` counts failures and errors.
  """

  @type facts :: %{
          optional(:cancelled) => boolean(),
          optional(:timed_out) => boolean(),
          optional(:started) => boolean(),
          optional(:oom_killed) => boolean(),
          optional(:container_missing) => boolean(),
          optional(:exit_code) => integer() | nil,
          optional(:junit) => %{failed: non_neg_integer()} | nil,
          optional(:error) => String.t() | nil
        }

  @spec decide(facts()) :: {TestFleet.Execution.Result.status(), String.t() | nil}
  def decide(facts) do
    exit_code = facts[:exit_code]
    junit = facts[:junit]

    cond do
      facts[:cancelled] -> {:cancelled, nil}
      facts[:timed_out] -> {:timeout, nil}
      !facts[:started] -> {:error, facts[:error] || "container did not start"}
      facts[:oom_killed] -> {:error, "memory limit exceeded"}
      facts[:container_missing] -> {:error, "container disappeared"}
      # 6: a suite that swallowed its own exit code
      exit_code == 0 and junit != nil and junit.failed > 0 -> {:failed, nil}
      exit_code == 0 -> {:passed, nil}
      # 8
      is_integer(exit_code) and junit != nil and junit.failed > 0 -> {:failed, nil}
      # 9: setup, teardown, a reporter, or the runner crashed, not a test
      is_integer(exit_code) and junit != nil -> {:error, crashed_message(exit_code)}
      # 10: without JUnit, a false "error" would be worse than a false "failed"
      is_integer(exit_code) -> {:failed, nil}
      true -> {:error, facts[:error] || "exit code unknown"}
    end
  end

  defp crashed_message(exit_code),
    do: "The suite exited with code #{exit_code}, but its JUnit report has no failures"
end
