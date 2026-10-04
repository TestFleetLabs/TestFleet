defmodule TestFleetWeb.ArtifactController do
  @moduledoc """
  Serves one artifact of a run of the user's organization. The name is looked up in
  the run's `artifacts` rows; unknown names are 404. `TestFleetWeb.ArtifactResponse`
  sends the file with its safety headers.
  """
  use TestFleetWeb, :controller

  alias TestFleet.{Artifacts, Runs}
  alias TestFleetWeb.ArtifactResponse

  def show(conn, %{"id" => run_id, "name" => segments}) do
    with {run_id, ""} <- Integer.parse(run_id),
         %{} = run <- Runs.get_run(conn.assigns.current_scope, run_id),
         %{} = artifact <- Artifacts.get_artifact(run, Enum.join(segments, "/")),
         %Plug.Conn{} = conn <- ArtifactResponse.send_artifact(conn, artifact) do
      conn
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
