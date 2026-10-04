defmodule TestFleetWeb.APIAuth do
  @moduledoc """
  Authenticates API requests by their bearer token, and
  nothing else: no session, no cookies, so there is no cross-site request forgery
  to defend against, and a logged-in browser cannot call the API.

  Assigns `current_scope` and `api_token`. Missing, unknown, and expired tokens,
  and tokens of deactivated users, all get the same `401`.
  """
  @behaviour Plug

  import Plug.Conn

  alias TestFleet.Accounts
  alias TestFleet.Accounts.Scope
  alias TestFleetWeb.API.Error

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {user, api_token} <- Accounts.get_user_by_api_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> assign(:api_token, api_token)
    else
      _ ->
        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="TestFleet"))
        |> Error.send_error(
          401,
          "unauthorized",
          "A valid API token is required: Authorization: Bearer <token>."
        )
        |> halt()
    end
  end

  # The scheme is case-insensitive (RFC 9110).
  defp bearer_token(conn) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme) do
      {:ok, String.trim(token)}
    else
      _ -> :error
    end
  end
end
