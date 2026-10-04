defmodule TestFleetWeb.API.TestDefinitionController do
  @moduledoc """
  Reads a test definition and updates its image from CI:
  a pipeline that deploys version 1.4.2 of an application moves its E2E suite to
  the matching image. Only the image can be changed here; everything else stays in
  the web UI.
  """
  use TestFleetWeb, :controller

  alias TestFleet.TestDefinitions
  alias TestFleetWeb.API.{Body, Lookup}

  action_fallback TestFleetWeb.API.FallbackController

  def show(conn, %{"project" => project_slug, "slug" => slug}) do
    with {:ok, project} <- Lookup.project(conn.assigns.current_scope, project_slug),
         {:ok, test_definition} <- Lookup.test_definition(project, slug) do
      render(conn, :show, test_definition: test_definition, project: project)
    end
  end

  def update(conn, %{"project" => project_slug, "slug" => slug}) do
    with {:ok, body} <- Body.fetch(conn, [], ~w(image tag)),
         {:ok, change} <- image_change(body),
         {:ok, project} <- Lookup.project(conn.assigns.current_scope, project_slug),
         {:ok, test_definition} <- Lookup.test_definition(project, slug),
         {:ok, test_definition} <- TestDefinitions.update_image(test_definition, change) do
      render(conn, :show, test_definition: test_definition, project: project)
    end
  end

  defp image_change(%{"image" => _, "tag" => _}),
    do: {:error, :invalid, %{"tag" => ["cannot be given together with image"]}}

  defp image_change(%{"image" => image}), do: {:ok, {:image, image}}
  defp image_change(%{"tag" => tag}), do: {:ok, {:tag, tag}}
  defp image_change(_body), do: {:error, :invalid, %{"image" => ["give image or tag"]}}
end
