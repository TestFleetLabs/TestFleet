defmodule TestFleet.ProjectsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Projects` context.
  """

  import TestFleet.OrganizationsFixtures, only: [org_scope: 0, org_scope: 1]

  def unique_project_name, do: "Project #{System.unique_integer([:positive])}"

  @doc "A project of `:organization` (default: the installation's)."
  def project_fixture(attrs \\ %{}) do
    {organization, attrs} = attrs |> Map.new() |> Map.pop(:organization)
    scope = if organization, do: org_scope(organization), else: org_scope()

    {:ok, project} =
      attrs
      |> Enum.into(%{name: unique_project_name(), description: "Customer-facing web shop"})
      |> then(&TestFleet.Projects.create_project(scope, &1))

    project
  end
end
