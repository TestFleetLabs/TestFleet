defmodule TestFleet.Retention do
  @moduledoc """
  Expires old artifacts and logs.
  Runs and test results are kept.

      config :testfleet, TestFleet.Retention,
        artifacts_days: 30,   # ARTIFACT_RETENTION_DAYS
        logs_days: 90         # LOG_RETENTION_DAYS

  A run's artifacts expire `artifacts_days` after `finished_at`, its logs
  `logs_days` after. Exempt are pinned runs, and the latest run per test
  definition and environment that ended `failed`, `timeout`, or `error`.

  Each call handles at most 100 runs for artifacts and 100 for logs, oldest
  first; a backlog shrinks over the next calls without long transactions. Only
  runs that still have artifact rows or log lines are considered, so a run
  without them is never marked expired.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Artifacts.{Artifact, Storage}
  alias TestFleet.Repo
  alias TestFleet.Runs
  alias TestFleet.Runs.{LogLine, Run}

  @batch_size 100
  @log_chunk 10_000
  @failures [:failed, :timeout, :error]

  @doc "Days after which artifacts expire (`ARTIFACT_RETENTION_DAYS`, default 30)."
  def artifacts_days, do: config(:artifacts_days, 30)

  @doc "Days after which logs expire (`LOG_RETENTION_DAYS`, default 90)."
  def logs_days, do: config(:logs_days, 90)

  defp config(key, default), do: Application.get_env(:testfleet, __MODULE__, [])[key] || default

  @doc """
  Expires what is due at `now`. Returns how many runs lost their artifacts and
  their logs.
  """
  def run(now \\ DateTime.utc_now()) do
    # The columns are utc_datetime_usec.
    now = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    artifacts =
      now
      |> due(artifacts_days(), :artifacts_expired_at, Artifact)
      |> Enum.map(&expire_artifacts(&1, now))

    logs =
      now
      |> due(logs_days(), :logs_expired_at, LogLine)
      |> Enum.map(&expire_logs(&1, now))

    %{artifacts: length(artifacts), logs: length(logs)}
  end

  # Runs whose `expired_field` is due, that still have rows in `schema`.
  defp due(now, days, expired_field, schema) do
    cutoff = DateTime.add(now, -days, :day)

    Repo.all(
      from r in Run,
        as: :run,
        where:
          r.status in ^Run.final_statuses() and r.finished_at <= ^cutoff and not r.pinned and
            is_nil(field(r, ^expired_field)),
        where: exists(from x in schema, where: x.run_id == parent_as(:run).id, select: 1),
        where: not (r.status in ^@failures and not exists(later_failure())),
        order_by: r.id,
        limit: @batch_size
    )
  end

  # A later run of the same test definition and environment that also failed.
  defp later_failure do
    from l in Run,
      where:
        l.test_definition_id == parent_as(:run).test_definition_id and
          l.environment_id == parent_as(:run).environment_id and
          l.status in ^@failures and l.id > parent_as(:run).id,
      select: 1
  end

  # The directory goes first: a crash in between leaves rows without files, which
  # the page shows as missing, never files nobody can find.
  defp expire_artifacts(%Run{id: id}, now) do
    File.rm_rf!(Storage.run_dir(id))

    Repo.transaction(fn ->
      Repo.delete_all(from a in Artifact, where: a.run_id == ^id)
      mark(id, :artifacts_expired_at, now)
    end)

    Runs.broadcast_updated(id)
  end

  defp expire_logs(%Run{id: id}, now) do
    delete_log_chunks(id)
    mark(id, :logs_expired_at, now)
    Runs.broadcast_updated(id)
  end

  defp delete_log_chunks(run_id) do
    chunk = from l in LogLine, where: l.run_id == ^run_id, select: l.id, limit: @log_chunk

    case Repo.delete_all(from l in LogLine, where: l.id in subquery(chunk)) do
      {@log_chunk, _} -> delete_log_chunks(run_id)
      {_count, _} -> :ok
    end
  end

  defp mark(run_id, field, now) do
    Repo.update_all(from(r in Run, where: r.id == ^run_id),
      set: [{field, now}, updated_at: DateTime.utc_now()]
    )
  end
end
