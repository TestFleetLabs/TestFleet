defmodule TestFleetWeb.API.RunController do
  @moduledoc """
  Starts, reads, and cancels runs from CI. API runs go
  through the same pipeline as every other run: they are
  created `queued` with `trigger = api`, the token's user, and the token.
  """
  use TestFleetWeb, :controller

  alias TestFleet.Runs
  alias TestFleetWeb.API.{Body, Lookup}

  action_fallback TestFleetWeb.API.FallbackController

  def create(conn, %{"project" => project_slug}) do
    with {:ok, body} <- Body.fetch(conn, ~w(test_definition environment)),
         {:ok, project} <- Lookup.project(project_slug),
         {:ok, test_definition} <- Lookup.test_definition(project, body["test_definition"]),
         {:ok, environment} <- Lookup.environment(project, body["environment"]),
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
    with {:ok, run} <- Lookup.run(id), do: render(conn, :show, run: run)
  end

  # Idempotent: a finished run is answered as it is. An active run reaches
  # `cancelled` once its container has stopped.
  def cancel(conn, %{"id" => id}) do
    with {:ok, run} <- Lookup.run(id) do
      :ok = Runs.cancel_run(run)

      conn
      |> put_status(:accepted)
      |> render(:show, run: Runs.get_run!(run.id))
    end
  end
end
