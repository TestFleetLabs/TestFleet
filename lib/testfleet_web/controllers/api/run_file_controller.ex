defmodule TestFleetWeb.API.RunFileController do
  @moduledoc """
  A run's log and artifacts over the API.

  The log is plain text, streamed like the web download. `?after=<sequence>` sends
  only newer lines, and `TestFleet-Log-Sequence` names the last line sent, so a
  pipeline can print the log while it waits. Artifact files are always sent as
  attachments, with the web UI's safety headers (`TestFleetWeb.ArtifactResponse`).
  """
  use TestFleetWeb, :controller

  alias TestFleet.Artifacts
  alias TestFleetWeb.{ArtifactResponse, RunLogController}
  alias TestFleetWeb.API.Lookup

  action_fallback TestFleetWeb.API.FallbackController

  def log(conn, %{"id" => id} = params) do
    with {:ok, run} <- Lookup.run(conn.assigns.current_scope, id),
         :ok <- not_expired(run.logs_expired_at, "log"),
         {:ok, after_sequence} <- after_param(params) do
      RunLogController.send_log(conn, run, after: after_sequence)
    end
  end

  def artifacts(conn, %{"id" => id}) do
    with {:ok, run} <- Lookup.run(conn.assigns.current_scope, id),
         :ok <- not_expired(run.artifacts_expired_at, "artifacts") do
      render(conn, :artifacts, run: run, artifacts: Artifacts.list_artifacts(run))
    end
  end

  def artifact(conn, %{"id" => id, "name" => segments}) do
    name = Enum.join(segments, "/")

    with {:ok, run} <- Lookup.run(conn.assigns.current_scope, id),
         :ok <- not_expired(run.artifacts_expired_at, "artifacts"),
         {:ok, artifact} <- fetch_artifact(run, name) do
      # :error when the row has no file (a crash during retention)
      case ArtifactResponse.send_artifact(conn, artifact, disposition: :attachment) do
        :error -> not_found(run, name)
        conn -> conn
      end
    end
  end

  defp fetch_artifact(run, name) do
    case Artifacts.get_artifact(run, name) do
      nil -> not_found(run, name)
      artifact -> {:ok, artifact}
    end
  end

  defp not_found(run, name), do: {:error, :not_found, ~s(No artifact "#{name}" in run #{run.id}.)}

  defp not_expired(nil, _what), do: :ok

  defp not_expired(%DateTime{} = expired_at, what),
    do: {:error, :expired, "The #{what} of this run expired on #{Date.to_iso8601(expired_at)}."}

  defp after_param(%{"after" => value}) do
    case Integer.parse(value) do
      {sequence, ""} when sequence >= 0 -> {:ok, sequence}
      _ -> {:error, :invalid, %{"after" => ["must be a sequence number"]}}
    end
  end

  defp after_param(_params), do: {:ok, nil}
end
