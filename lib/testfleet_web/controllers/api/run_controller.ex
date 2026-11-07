defmodule TestFleetWeb.API.RunController do
  @moduledoc """
  Starts, reads, and cancels runs from CI. API runs go
  through the same pipeline as every other run: they are
  created `queued` with `trigger = api`, the token's user, and the token, plus
  the deployment the pipeline reports, if any.
  """
  use TestFleetWeb, :controller

  alias TestFleet.Runs
  alias TestFleet.Runs.Deployment
  alias TestFleetWeb.API.{Body, Lookup}

  action_fallback TestFleetWeb.API.FallbackController

  def create(conn, %{"project" => project_slug}) do
    with {:ok, body} <-
           Body.fetch(conn, ~w(test_definition environment), [
             {"deployment", Deployment.fields()}
           ]),
         {:ok, deployment} <- deployment(body["deployment"]),
         {:ok, project} <- Lookup.project(conn.assigns.current_scope, project_slug),
         {:ok, test_definition} <- Lookup.test_definition(project, body["test_definition"]),
         {:ok, environment} <- Lookup.environment(project, body["environment"]),
         {:ok, run} <-
           Runs.create_run(test_definition, environment,
             trigger: :api,
             user: conn.assigns.current_scope.user,
             api_token: conn.assigns.api_token,
             deployment: deployment
           ) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/v1/runs/#{run}")
      |> render(:show, run: run)
    end
  end

  # Problems are named "deployment.<field>", like Body names unknown keys.
  defp deployment(params) do
    with {:error, changeset} <- Deployment.new(params) do
      details =
        changeset
        |> Ecto.Changeset.traverse_errors(&TestFleetWeb.CoreComponents.translate_error/1)
        |> Map.new(fn {field, messages} -> {"deployment.#{field}", messages} end)

      {:error, :invalid, details}
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, run} <- Lookup.run(conn.assigns.current_scope, id),
         do: render(conn, :show, run: run)
  end

  # Idempotent: a finished run is answered as it is. An active run reaches
  # `cancelled` once its container has stopped.
  def cancel(conn, %{"id" => id}) do
    with {:ok, run} <- Lookup.run(conn.assigns.current_scope, id) do
      :ok = Runs.cancel_run(run)

      conn
      |> put_status(:accepted)
      |> render(:show, run: Runs.get_run!(conn.assigns.current_scope, run.id))
    end
  end
end
