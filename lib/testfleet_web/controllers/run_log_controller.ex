defmodule TestFleetWeb.RunLogController do
  @moduledoc """
  Downloads a run's stored log as plain text, streamed
  from PostgreSQL in chunks. The lines are stored masked.

  `send_log/3` is shared with the API.
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
        conn
        |> put_resp_header("content-disposition", ~s(attachment; filename="run-#{run.id}.log"))
        |> send_log(run)
    end
  end

  @doc """
  Streams the stored log. With `after: sequence`, only the lines after it, without
  the truncation notice, so a client that polls does not print it every time.
  Lines stored while streaming are left for the next request: the log ends at the
  last line stored when the request came in, `through`, which is returned.
  """
  def send_log(conn, run, opts \\ []) do
    through = Runs.last_log_sequence(run)
    after_sequence = opts[:after]
    window = [through: through] ++ if(after_sequence, do: [after: after_sequence], else: [])

    conn =
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header(
        "testfleet-log-sequence",
        Integer.to_string(max(through, after_sequence || 0))
      )
      |> send_chunked(200)

    conn =
      Runs.reduce_log(
        run,
        conn,
        fn lines, conn ->
          {:ok, conn} = chunk(conn, Enum.map(lines, &[&1.content, ?\n]))
          conn
        end,
        window
      )

    if run.log_truncated and is_nil(after_sequence) do
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
