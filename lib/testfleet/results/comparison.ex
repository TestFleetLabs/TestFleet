defmodule TestFleet.Results.Comparison do
  @moduledoc """
  Two final runs of a test definition side by side, test by test (spec section 10).

  `diff/2` is pure: it groups the outcomes of a run and its baseline by identity.
  `TestFleet.Results.compare/2` loads them and sets `run` and `baseline`.

  Each group is `%{total: n, tests: [...]}`, at most 100 tests listed, sorted by
  suite, classname, and name. A test is a map with `suite`, `classname`, `name`,
  `outcome`, and `failure_message` (of this run; for `removed`, of the baseline).
  """

  @max_listed 100
  @red [:failed, :error]
  @groups [:new_failures, :fixed, :still_failing, :added, :removed]

  defstruct run: nil,
            baseline: nil,
            new_failures: %{total: 0, tests: []},
            fixed: %{total: 0, tests: []},
            still_failing: %{total: 0, tests: []},
            added: %{total: 0, tests: []},
            removed: %{total: 0, tests: []}

  @doc "The groups, in the order the run page shows them."
  def groups, do: @groups

  @doc """
  Groups `current` against `baseline`, both lists of outcomes, one per identity:

  - `new_failures`: red now, `passed` in the baseline
  - `fixed`: `passed` now, red in the baseline
  - `still_failing`: red in both
  - `added`: only in this run; `removed`: only in the baseline

  A test skipped in either run, or passed in both, is in no group.
  """
  def diff(current, baseline) do
    in_baseline = Map.new(baseline, &{identity(&1), &1.outcome})
    in_current = MapSet.new(current, &identity/1)

    grouped =
      current
      |> Enum.group_by(&group(&1.outcome, Map.fetch(in_baseline, identity(&1))))
      |> Map.delete(nil)
      |> Map.put(:removed, Enum.reject(baseline, &MapSet.member?(in_current, identity(&1))))

    Enum.reduce(@groups, %__MODULE__{}, fn group, comparison ->
      tests = Map.get(grouped, group, [])

      Map.put(comparison, group, %{
        total: length(tests),
        tests: tests |> Enum.sort_by(&identity/1) |> Enum.take(@max_listed)
      })
    end)
  end

  defp group(_outcome, :error), do: :added
  defp group(outcome, {:ok, :passed}) when outcome in @red, do: :new_failures
  defp group(:passed, {:ok, before}) when before in @red, do: :fixed
  defp group(outcome, {:ok, before}) when outcome in @red and before in @red, do: :still_failing
  defp group(_outcome, {:ok, _before}), do: nil

  defp identity(%{suite: suite, classname: classname, name: name}), do: {suite, classname, name}
end
