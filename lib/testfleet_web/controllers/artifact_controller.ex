defmodule TestFleetWeb.ArtifactController do
  @moduledoc """
  Serves one artifact of a run of the user's organization. The name is looked up in
  the run's `artifacts` rows; unknown names are 404. `TestFleetWeb.ArtifactResponse`
  sends the file with its safety headers. `archive/2` sends all of them as one ZIP.
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

  @doc """
  All of a run's artifacts as one ZIP archive, `run-<id>-artifacts.zip`, streamed
  while it is written. The response starts with the first piece, so a run that
  cannot be archived still gets a plain error.
  """
  def archive(conn, %{"id" => run_id}) do
    with {run_id, ""} <- Integer.parse(run_id),
         %{} = run <- Runs.get_run(conn.assigns.current_scope, run_id),
         {result, conn} when result in [:ok, :halted] <-
           Artifacts.reduce_zip(run, conn, &send_piece(&1, &2, run)) do
      conn
    else
      {:error, :too_large} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(
          422,
          "The artifacts are too large for one ZIP archive. Download them one by one or through the API.\n"
        )

      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp send_piece(data, conn, run) do
    conn =
      if conn.state == :chunked do
        conn
      else
        conn
        |> put_resp_content_type("application/zip", nil)
        |> put_resp_header(
          "content-disposition",
          ~s(attachment; filename="run-#{run.id}-artifacts.zip")
        )
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_chunked(200)
      end

    case chunk(conn, data) do
      {:ok, conn} -> {:cont, conn}
      # The client went away.
      {:error, _reason} -> {:halt, conn}
    end
  end
end
