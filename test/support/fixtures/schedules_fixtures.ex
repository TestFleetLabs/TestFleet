defmodule TestFleet.SchedulesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Schedules` context.
  """

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.TestDefinitionsFixtures

  @doc """
  Creates a schedule. Pass `:project`, `:test_definition`, and `:environment` to
  reuse them; missing ones are created in the same project.
  """
  def schedule_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    {project, attrs} = Map.pop_lazy(attrs, :project, fn -> project_fixture() end)

    {test_definition, attrs} =
      Map.pop_lazy(attrs, :test_definition, fn -> test_definition_fixture(project: project) end)

    {environment, attrs} =
      Map.pop_lazy(attrs, :environment, fn -> environment_fixture(project: project) end)

    {opts, attrs} = Map.split(attrs, [:now])

    {:ok, schedule} =
      attrs
      |> Enum.into(%{
        test_definition_id: test_definition.id,
        environment_id: environment.id,
        cron_expression: "0 6 * * *",
        timezone: "Europe/Vienna"
      })
      |> then(&TestFleet.Schedules.create_schedule(project, &1, Keyword.new(opts)))

    schedule
  end
end
