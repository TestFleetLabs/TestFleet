defmodule TestFleet.EnvironmentsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Environments` context.
  """

  import TestFleet.ProjectsFixtures

  def environment_fixture(attrs \\ %{}) do
    {project, attrs} = Map.pop_lazy(Map.new(attrs), :project, fn -> project_fixture() end)

    {:ok, environment} =
      attrs
      |> Enum.into(%{name: "Staging #{System.unique_integer([:positive])}"})
      |> then(&TestFleet.Environments.create_environment(project, &1))

    environment
  end

  def variable_fixture(environment, attrs \\ %{}) do
    {:ok, variable} =
      attrs
      |> Enum.into(%{key: "VAR_#{System.unique_integer([:positive])}", value: "value"})
      |> then(&TestFleet.Environments.create_variable(environment, &1))

    variable
  end
end
