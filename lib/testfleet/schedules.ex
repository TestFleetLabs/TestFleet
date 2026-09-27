defmodule TestFleet.Schedules do
  @moduledoc """
  Schedules: when a test definition runs against an environment (main spec
  section 28). `tick/1` creates the runs of due schedules (Milestone 5).
  """

  import Ecto.Query, warn: false

  require Logger

  alias TestFleet.Environments.Environment
  alias TestFleet.Runs
  alias TestFleet.Projects.Project
  alias TestFleet.Repo
  alias TestFleet.Schedules.{Cron, Schedule}
  alias TestFleet.TestDefinitions.TestDefinition

  @doc "A project's schedules, soonest first, with test definition and environment."
  def list_schedules(%Project{id: project_id}) do
    Repo.all(
      from s in Schedule,
        join: t in assoc(s, :test_definition),
        join: e in assoc(s, :environment),
        where: t.project_id == ^project_id,
        order_by: [desc: s.enabled, asc: s.next_run_at],
        preload: [test_definition: t, environment: e]
    )
  end

  @doc "The next enabled schedules of all projects, with test definition, project, and environment."
  def list_upcoming(limit) do
    Repo.all(
      from s in Schedule,
        join: t in assoc(s, :test_definition),
        join: p in assoc(t, :project),
        join: e in assoc(s, :environment),
        where: s.enabled and t.enabled,
        order_by: [asc: s.next_run_at],
        limit: ^limit,
        preload: [test_definition: {t, project: p}, environment: e]
    )
  end

  def get_schedule!(%Project{id: project_id}, id) do
    Repo.one!(
      from s in Schedule,
        join: t in assoc(s, :test_definition),
        join: e in assoc(s, :environment),
        where: s.id == ^id and t.project_id == ^project_id,
        preload: [test_definition: t, environment: e]
    )
  end

  @doc "Options: `:now`, the time `next_run_at` is computed from (default: now)."
  def create_schedule(%Project{} = project, attrs, opts \\ []) do
    project
    |> changeset(%Schedule{}, attrs, opts)
    |> Repo.insert()
    |> preload()
  end

  def update_schedule(%Project{} = project, %Schedule{} = schedule, attrs, opts \\ []) do
    project
    |> changeset(schedule, attrs, opts)
    |> Repo.update()
    |> preload()
  end

  def delete_schedule(%Schedule{} = schedule), do: Repo.delete(schedule)

  def change_schedule(%Project{} = project, %Schedule{} = schedule, attrs \\ %{}, opts \\ []) do
    changeset(project, schedule, attrs, opts)
  end

  @doc """
  The next `count` run times for a cron expression and time zone, in that time
  zone, for previews while typing. Empty if either is invalid.
  """
  def preview(expression, timezone, count, now \\ DateTime.utc_now())

  def preview(expression, timezone, count, now)
      when is_binary(expression) and is_binary(timezone) do
    with true <- TestFleet.Schedules.Timezones.valid?(timezone),
         {:ok, cron} <- Cron.parse(expression) do
      cron
      |> Cron.next_runs(timezone, now, count)
      |> Enum.map(&DateTime.shift_zone!(&1, timezone))
    else
      _ -> []
    end
  end

  def preview(_expression, _timezone, _count, _now), do: []

  ## The schedule tick (Milestone 5, section 4)

  @doc """
  Creates the runs of all due schedules and moves each to its next occurrence
  after `now`. Called every minute by `TestFleet.Schedules.TickWorker`.

  Each schedule is handled in its own transaction, with its row locked (`SKIP
  LOCKED`: a schedule another tick holds is left to it). Missed slots are coalesced
  into one run. Returns `[{schedule_id, outcome}]` for the schedules it handled.
  """
  def tick(%DateTime{} = now) do
    Repo.all(
      from s in Schedule,
        where: s.enabled and s.next_run_at <= ^now,
        order_by: [asc: s.next_run_at, asc: s.id],
        select: s.id
    )
    |> Enum.flat_map(fn id ->
      case tick_schedule(id, now) do
        :not_due -> []
        outcome -> [{id, outcome}]
      end
    end)
  end

  defp tick_schedule(id, now) do
    {:ok, result} =
      Repo.transaction(fn ->
        schedule =
          Repo.one(
            from s in Schedule,
              where: s.id == ^id and s.enabled and s.next_run_at <= ^now,
              lock: "FOR UPDATE SKIP LOCKED"
          )

        if schedule, do: fire(schedule, now), else: :not_due
      end)

    # After the commit, so the dispatcher never wakes up before the run is visible.
    case result do
      {:created, run} ->
        Runs.broadcast_created(run)
        :created

      outcome ->
        outcome
    end
  end

  defp fire(schedule, now) do
    case next_occurrence(schedule, now) do
      {:ok, next_run_at} ->
        log_missed_slots(schedule, now)
        slot = schedule.next_run_at

        {outcome, changes, result} =
          case Runs.create_scheduled(schedule, slot, now) do
            {:ok, :exists} ->
              {:created, [], :created}

            {:ok, run} ->
              {:created, [last_run_id: run.id], {:created, run}}

            {:skipped, :overlap} ->
              Logger.info(
                "schedule #{schedule.id}: skipped #{slot}, its previous run is unfinished"
              )

              {:skipped_overlap, [], :skipped_overlap}

            {:skipped, :test_definition_disabled} ->
              {:skipped_disabled, [], :skipped_disabled}
          end

        update_tick(
          schedule,
          [next_run_at: next_run_at, last_tick_at: slot, last_tick_outcome: outcome] ++ changes
        )

        result

      {:error, reason} ->
        Logger.error("schedule #{schedule.id}: disabled, #{reason}")
        update_tick(schedule, enabled: false)
        :disabled
    end
  end

  # The form prevents broken schedules; data changed by hand, or a time zone removed
  # from the database, must not fail every minute.
  defp next_occurrence(schedule, now) do
    with {:tz, true} <- {:tz, TestFleet.Schedules.Timezones.valid?(schedule.timezone)},
         {:ok, cron} <- Cron.parse(schedule.cron_expression),
         {:ok, next_run_at} <- Cron.next_run(cron, schedule.timezone, now) do
      {:ok, next_run_at}
    else
      {:tz, false} -> {:error, "unknown time zone #{inspect(schedule.timezone)}"}
      {:error, :never} -> {:error, "#{inspect(schedule.cron_expression)} never matches again"}
      {:error, message} -> {:error, "#{inspect(schedule.cron_expression)} #{message}"}
    end
  end

  # One run covers all missed slots; the log says how many there were.
  @max_counted_slots 1_000

  defp log_missed_slots(schedule, now) do
    {:ok, cron} = Cron.parse(schedule.cron_expression)

    missed =
      cron
      |> Cron.next_runs(schedule.timezone, schedule.next_run_at, @max_counted_slots)
      |> Enum.count(&(DateTime.compare(&1, now) != :gt))

    if missed > 0 do
      count = if missed == @max_counted_slots, do: "#{missed}+", else: "#{missed}"

      Logger.warning(
        "schedule #{schedule.id}: one run for #{schedule.next_run_at}, " <>
          "covering #{count} missed later slot(s)"
      )
    end
  end

  # Not through a changeset: `updated_at` means "configuration changed".
  defp update_tick(schedule, changes) do
    Repo.update_all(from(s in Schedule, where: s.id == ^schedule.id), set: changes)
  end

  defp changeset(%Project{id: project_id}, schedule, attrs, opts) do
    test_definition_ids =
      Repo.all(
        from t in TestDefinition, where: t.project_id == ^project_id and t.enabled, select: t.id
      )

    environment_ids =
      Repo.all(from e in Environment, where: e.project_id == ^project_id, select: e.id)

    Schedule.changeset(
      schedule,
      attrs,
      Keyword.merge(opts,
        test_definition_ids: test_definition_ids,
        environment_ids: environment_ids
      )
    )
  end

  defp preload({:ok, schedule}),
    do: {:ok, Repo.preload(schedule, [:test_definition, :environment], force: true)}

  defp preload(error), do: error
end
