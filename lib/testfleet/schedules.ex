defmodule TestFleet.Schedules do
  @moduledoc """
  Schedules: when a test definition runs against an environment (main spec
  section 28). Creating runs from due schedules is the schedule tick (Milestone 5).
  """

  import Ecto.Query, warn: false

  alias TestFleet.Environments.Environment
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
