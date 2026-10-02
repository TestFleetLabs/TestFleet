defmodule TestFleetWeb.API.Lookup do
  @moduledoc """
  Finds what an API request names, by slug or id (Milestone 11, section 5). Not
  found is `{:error, :not_found, message}`, naming what is missing.
  """
  alias TestFleet.{Environments, Projects, Runs, TestDefinitions}

  def project(slug) do
    case Projects.get_project_by_slug(slug) do
      nil -> {:error, :not_found, ~s(No project "#{slug}".)}
      project -> {:ok, project}
    end
  end

  def test_definition(project, slug) do
    case TestDefinitions.get_test_definition_by_slug(project, slug) do
      nil -> {:error, :not_found, ~s(No test definition "#{slug}" in project "#{project.slug}".)}
      test_definition -> {:ok, test_definition}
    end
  end

  def environment(project, slug) do
    case Environments.get_environment_by_slug(project, slug) do
      nil -> {:error, :not_found, ~s(No environment "#{slug}" in project "#{project.slug}".)}
      environment -> {:ok, environment}
    end
  end

  def run(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = run <- Runs.get_run(id) do
      {:ok, run}
    else
      _ -> {:error, :not_found, ~s(No run "#{id}".)}
    end
  end
end
