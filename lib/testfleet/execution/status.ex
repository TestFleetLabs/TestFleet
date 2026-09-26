defmodule TestFleet.Execution.Status do
  @moduledoc """
  Decides the final status of a run (main spec section 24).

  The first matching rule wins. The JUnit rules (6, 8, 9) come with result parsing.
  """

  @type facts :: %{
          optional(:cancelled) => boolean(),
          optional(:timed_out) => boolean(),
          optional(:started) => boolean(),
          optional(:oom_killed) => boolean(),
          optional(:container_missing) => boolean(),
          optional(:exit_code) => integer() | nil,
          optional(:error) => String.t() | nil
        }

  @spec decide(facts()) :: {TestFleet.Execution.Result.status(), String.t() | nil}
  def decide(facts) do
    cond do
      facts[:cancelled] -> {:cancelled, nil}
      facts[:timed_out] -> {:timeout, nil}
      !facts[:started] -> {:error, facts[:error] || "container did not start"}
      facts[:oom_killed] -> {:error, "memory limit exceeded"}
      facts[:container_missing] -> {:error, "container disappeared"}
      facts[:exit_code] == 0 -> {:passed, nil}
      is_integer(facts[:exit_code]) -> {:failed, nil}
      true -> {:error, facts[:error] || "exit code unknown"}
    end
  end
end
