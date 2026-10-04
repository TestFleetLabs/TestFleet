defmodule TestFleet.RunsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Runs` context.
  """

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Repo

  @doc """
  Creates a manual run. Pass `:project`, `:test_definition`, and `:environment` to
  reuse them; missing ones are created in the same project. Other attributes, such
  as `:status`, are written directly, bypassing the status transitions.
  """
  def run_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)

    {project, attrs} =
      Map.pop_lazy(attrs, :project, fn ->
        case attrs do
          %{test_definition: %{project_id: id}} -> Repo.get!(TestFleet.Projects.Project, id)
          _ -> project_fixture()
        end
      end)

    {test_definition, attrs} =
      Map.pop_lazy(attrs, :test_definition, fn -> test_definition_fixture(project: project) end)

    {environment, attrs} =
      Map.pop_lazy(attrs, :environment, fn -> environment_fixture(project: project) end)

    {:ok, run} = TestFleet.Runs.create_run(test_definition, environment)

    if attrs == %{} do
      run
    else
      run |> Ecto.Changeset.change(attrs) |> Repo.update!()
    end
  end
end
