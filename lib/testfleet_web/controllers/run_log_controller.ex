defmodule TestFleetWeb.RunLogController do
  @moduledoc """
  Downloads a run's stored log as plain text (Milestone 4, section 8), streamed
  from PostgreSQL in chunks. The lines are stored masked.
  """
  use TestFleetWeb, :controller

  alias TestFleet.Runs

  def show(conn, %{"id" => id}) do
    case Runs.get_run!(id) do
      %{logs_expired_at: %DateTime{} = expired_at} ->
        conn
        |> put_resp_content_type("text/plain")
        |> send_resp(410, "The log of this run expired on #{Date.to_iso8601(expired_at)}.\n")

      run ->
        send_log(conn, run)
    end
  end

  defp send_log(conn, run) do
    conn =
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("content-disposition", ~s(attachment; filename="run-#{run.id}.log"))
      |> send_chunked(200)

    conn =
      Runs.reduce_log(run, conn, fn lines, conn ->
        {:ok, conn} = chunk(conn, Enum.map(lines, &[&1.content, ?\n]))
        conn
      end)

    if run.log_truncated do
      {:ok, conn} = chunk(conn, [truncation_notice(), ?\n])
      conn
    else
      conn
    end
  end

  @doc false
  def truncation_notice do
    "[TestFleet] Log limit of #{TestFleetWeb.AppComponents.format_bytes(Runs.max_log_bytes())} reached. Later output was not stored."
  end
end
