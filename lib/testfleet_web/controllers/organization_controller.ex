defmodule TestFleetWeb.OrganizationController do
  @moduledoc """
  The ways into an organization: `/` opens the user's organization, and `/runs/:id`
  (the links sent before runs had their organization in the path) opens the run in
  its organization.
  """
  use TestFleetWeb, :controller

  alias TestFleet.{Organizations, Runs}

  @doc "With one organization, opens it; otherwise the list to choose from."
  def home(conn, _params) do
    case Organizations.list_memberships(conn.assigns.current_scope.user) do
      [%{organization: organization}] -> redirect(conn, to: ~p"/#{organization}")
      _none_or_several -> redirect(conn, to: ~p"/organizations")
    end
  end

  @doc "Redirects to the run in its organization, for members; otherwise 404."
  def run(conn, %{"id" => id}) do
    with {id, ""} <- Integer.parse(id),
         %{} = run <- Runs.get_run(id),
         %{} <- Organizations.get_membership(conn.assigns.current_scope.user, run.organization) do
      redirect(conn, to: ~p"/#{run.organization}/runs/#{run.id}")
    else
      _ -> conn |> put_status(:not_found) |> put_view(TestFleetWeb.ErrorHTML) |> render(:"404")
    end
  end
end
