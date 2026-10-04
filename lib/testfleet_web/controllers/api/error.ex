defmodule TestFleetWeb.API.Error do
  @moduledoc """
  Sends an API error:

      {"error": {"code": "not_found", "message": "…", "details": {…}}}

  `details` only for validation errors.
  """
  import Plug.Conn

  def send_error(conn, status, code, message, details \\ nil) do
    error = %{code: code, message: message}
    error = if details, do: Map.put(error, :details, details), else: error

    conn
    |> put_status(status)
    |> Phoenix.Controller.json(%{error: error})
  end
end
