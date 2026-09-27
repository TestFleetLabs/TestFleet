defmodule TestFleet.TestDefinitionsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.TestDefinitions` context.
  """

  import TestFleet.ProjectsFixtures

  def test_definition_fixture(attrs \\ %{}) do
    {project, attrs} = Map.pop_lazy(Map.new(attrs), :project, fn -> project_fixture() end)

    {:ok, test_definition} =
      attrs
      |> Enum.into(%{
        name: "Suite #{System.unique_integer([:positive])}",
        image: "registry.company.com/customer-a/e2e:1.17"
      })
      |> then(&TestFleet.TestDefinitions.create_test_definition(project, &1))

    test_definition
  end
end
