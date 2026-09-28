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

  @doc "A run's test results: failed and errored first, then in report order."
  def list_test_results(%Run{id: run_id}) do
    Repo.all(
      from t in TestResult,
        where: t.run_id == ^run_id,
        order_by: [
          asc: fragment("CASE WHEN ? IN ('failed', 'error') THEN 0 ELSE 1 END", t.status),
          asc: t.id
        ]
    )
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
