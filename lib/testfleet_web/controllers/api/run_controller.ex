defmodule TestFleetWeb.API.RunController do
  @moduledoc """
  Starts, reads, and cancels runs from CI (Milestone 11, section 6). API runs go
  through the same pipeline as every other run (main spec section 29): they are
  created `queued` with `trigger = api`, the token's user, and the token.
  """
  use TestFleetWeb, :controller

  alias TestFleet.{Environments, Projects, Runs, TestDefinitions}
  alias TestFleetWeb.API.Body

  action_fallback TestFleetWeb.API.FallbackController

  def create(conn, %{"project" => project_slug}) do
    with {:ok, body} <- Body.fetch(conn, ~w(test_definition environment)),
         {:ok, project} <- fetch_project(project_slug),
         {:ok, test_definition} <- fetch_test_definition(project, body["test_definition"]),
         {:ok, environment} <- fetch_environment(project, body["environment"]),
         {:ok, run} <-
           Runs.create_run(test_definition, environment,
             trigger: :api,
             user: conn.assigns.current_scope.user,
             api_token: conn.assigns.api_token
           ) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/runs/#{run}")
      |> render(:show, run: run)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, run} <- fetch_run(id), do: render(conn, :show, run: run)
  end

  # Idempotent: a finished run is answered as it is. An active run reaches
  # `cancelled` once its container has stopped (main spec section 26).
  def cancel(conn, %{"id" => id}) do
    with {:ok, run} <- fetch_run(id) do
      :ok = Runs.cancel_run(run)

      conn
      |> put_status(:accepted)
      |> render(:show, run: Runs.get_run!(run.id))
    end
  end

  defp fetch_project(slug) do
    case Projects.get_project_by_slug(slug) do
      nil -> {:error, :not_found, ~s(No project "#{slug}".)}
      project -> {:ok, project}
    end
  end

  defp fetch_test_definition(project, slug) do
    case TestDefinitions.get_test_definition_by_slug(project, slug) do
      nil -> {:error, :not_found, ~s(No test definition "#{slug}" in project "#{project.slug}".)}
      test_definition -> {:ok, test_definition}
    end
  end

  defp fetch_environment(project, slug) do
    case Environments.get_environment_by_slug(project, slug) do
      nil -> {:error, :not_found, ~s(No environment "#{slug}" in project "#{project.slug}".)}
      environment -> {:ok, environment}
    end
  end

  defp fetch_run(id) do
    with {id, ""} <- Integer.parse(id),
         %{} = run <- Runs.get_run(id) do
      {:ok, run}
    else
      _ -> {:error, :not_found, ~s(No run "#{id}".)}
    end
  end
end
