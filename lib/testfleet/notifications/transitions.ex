defmodule TestFleet.Notifications.Transitions do
  @moduledoc """
  Decides whether a run that just became final changed its series' state
  (Milestone 8, section 6). A series is all runs of one test definition in one
  environment.

  Verdicts: `passed` is green; `failed` and `timeout` are red; `error` has none (an
  infrastructure problem says nothing about the application); `cancelled` is
  ignored entirely.

  | Run       | Compared with                                          | Event           |
  |-----------|--------------------------------------------------------|-----------------|
  | red       | the latest earlier run with a verdict: green, or none   | `run.failing`   |
  | green     | the latest earlier run with a verdict: red              | `run.recovered` |
  | `error`   | the latest earlier non-cancelled run: not `error`, or none | `run.error`  |

  Everything else, including a red run after a red one, is no event.
  """

  @red [:failed, :timeout]

  @doc "The statuses that carry a verdict."
  def verdict_statuses, do: [:passed | @red]

  @doc """
  `run` is the finished run. `previous_verdict` is the latest earlier run of its
  series with a verdict, `previous_outcome` the latest earlier non-cancelled one;
  either may be `nil`. Returns `{event, previous}`, with the run compared against,
  or `:none`.
  """
  @spec event(map(), map() | nil, map() | nil) :: {String.t(), map() | nil} | :none
  def event(%{status: status}, previous_verdict, _previous_outcome) when status in @red do
    case previous_verdict do
      nil -> {"run.failing", nil}
      %{status: :passed} -> {"run.failing", previous_verdict}
      _still_red -> :none
    end
  end

  def event(%{status: :passed}, %{status: previous} = previous_verdict, _outcome)
      when previous in @red,
      do: {"run.recovered", previous_verdict}

  def event(%{status: :error}, _previous_verdict, previous_outcome) do
    case previous_outcome do
      %{status: :error} -> :none
      _ -> {"run.error", previous_outcome}
    end
  end

  def event(_run, _previous_verdict, _previous_outcome), do: :none
end
