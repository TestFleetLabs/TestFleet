defmodule TestFleetWeb.ArtifactController do
  @moduledoc """
  Serves one artifact of a run. The name is looked up in
  the run's `artifacts` rows; unknown names are 404. `TestFleetWeb.ArtifactResponse`
  sends the file with its safety headers.
  """
  use TestFleetWeb, :controller

  alias TestFleet.Artifacts
  alias TestFleetWeb.ArtifactResponse

  def show(conn, %{"id" => run_id, "name" => segments}) do
    with %{} = artifact <- Artifacts.get_artifact(run_id, Enum.join(segments, "/")),
         %Plug.Conn{} = conn <- ArtifactResponse.send_artifact(conn, artifact) do
      conn
    else
      _ -> send_resp(conn, 404, "Not found")
    end
  end
end
