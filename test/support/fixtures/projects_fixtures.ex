defmodule TestFleet.ProjectsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Projects` context.
  """

  def unique_project_name, do: "Project #{System.unique_integer([:positive])}"

  def project_fixture(attrs \\ %{}) do
    {:ok, project} =
      attrs
      |> Enum.into(%{name: unique_project_name(), description: "Customer-facing web shop"})
      |> TestFleet.Projects.create_project()

    project
  end
end
