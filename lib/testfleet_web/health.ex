defmodule TestFleetWeb.Health do
  @moduledoc """
  `GET /health`, for the container's health check and the reverse proxy.

  Healthy means the database answers. Docker's reachability is reported, but does not
  make TestFleet unhealthy: restarting TestFleet does not bring Docker back, and the
  dispatcher already holds runs while it is gone.

  It sits in the endpoint before request logging, so the checks stay out of the log.
  """

  @behaviour Plug

  import Plug.Conn

  alias TestFleet.Execution

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: method, path_info: ["health"]} = conn, _opts)
      when method in ["GET", "HEAD"] do
    {status, verdict} = if database_up?(), do: {200, "ok"}, else: {503, "error"}
    docker = if Execution.docker_status().reachable, do: "reachable", else: "unreachable"

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{status: verdict, docker: docker}))
    |> halt()
  end

  def call(conn, _opts), do: conn

  defp database_up? do
    match?({:ok, _}, Ecto.Adapters.SQL.query(TestFleet.Repo, "SELECT 1", [], timeout: 2_000))
  rescue
    DBConnection.ConnectionError -> false
  end
end
