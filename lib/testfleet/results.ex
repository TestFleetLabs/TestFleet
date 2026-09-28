defmodule TestFleet.Results do
  @moduledoc """
  Test results parsed from a run's JUnit report (main spec section 10, Milestone 6).

  `TestFleet.Results.JUnit` parses during execution; `Runs.finish/2` stores the
  rows with the run's final status.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Repo
  alias TestFleet.Results.TestResult
  alias TestFleet.Runs.Run

  @chunk_size 1_000

  @failures [:failed, :error]

  @doc """
  A run's test results: failed and errored first, then in report order.

  `only: :failures` returns the failed and errored ones, `only: :others` the rest;
  the run page loads the rest on demand.
  """
  def list_test_results(%Run{id: run_id}, opts \\ []) do
    query =
      from t in TestResult,
        where: t.run_id == ^run_id,
        order_by: [
          asc: fragment("CASE WHEN ? IN ('failed', 'error') THEN 0 ELSE 1 END", t.status),
          asc: t.id
        ]

    query =
      case opts[:only] do
        nil -> query
        :failures -> where(query, [t], t.status in ^@failures)
        :others -> where(query, [t], t.status not in ^@failures)
      end

    Repo.all(query)
  end

  @doc """
  The names of a run's first `limit` failed or errored tests, as
  `"<classname> › <name>"`, and how many failed in all. Names only: failure
  messages stay on the run page (Milestone 8, section 8).
  """
  def failure_summary(%Run{id: run_id}, limit \\ 3) do
    failures = from t in TestResult, where: t.run_id == ^run_id and t.status in ^@failures

    names =
      Repo.all(
        from t in failures, order_by: [asc: t.id], limit: ^limit, select: {t.classname, t.name}
      )
      |> Enum.map(fn
        {classname, name} when classname in [nil, ""] -> name
        {classname, name} -> "#{classname} › #{name}"
      end)

    %{names: names, count: Repo.aggregate(failures, :count)}
  end

  @doc "The sum of a run's test durations in milliseconds; `nil` without any."
  def total_duration_ms(%Run{id: run_id}) do
    Repo.one(from t in TestResult, where: t.run_id == ^run_id, select: sum(t.duration_ms))
  end

  @doc """
  The counts stored on a run: `tests_failed` includes errors. All `nil` without
  JUnit (`test_results` is `nil`).
  """
  def counts(nil), do: %{tests_passed: nil, tests_failed: nil, tests_skipped: nil}

  def counts(test_results) do
    frequencies = Enum.frequencies_by(test_results, & &1.status)

    %{
      tests_passed: Map.get(frequencies, :passed, 0),
      tests_failed: Map.get(frequencies, :failed, 0) + Map.get(frequencies, :error, 0),
      tests_skipped: Map.get(frequencies, :skipped, 0)
    }
  end

  @doc """
  Inserts parsed test cases (see `TestFleet.Results.JUnit`, plus `file`), in chunks
  of #{@chunk_size}. Called by `Runs.finish/2` inside its transaction.
  """
  def insert_all(_run, nil), do: :ok

  def insert_all(%Run{id: run_id, test_definition_id: test_definition_id}, test_results) do
    now = DateTime.utc_now()

    test_results
    |> Enum.map(fn result ->
      result
      |> Map.take([
        :suite,
        :classname,
        :name,
        :status,
        :duration_ms,
        :failure_message,
        :failure_details,
        :file
      ])
      |> Map.merge(%{run_id: run_id, test_definition_id: test_definition_id, inserted_at: now})
    end)
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(&Repo.insert_all(TestResult, &1))
  end
end
