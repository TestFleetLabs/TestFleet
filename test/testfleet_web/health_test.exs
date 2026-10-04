defmodule TestFleetWeb.HealthTest do
  # The health endpoint.
  use TestFleetWeb.ConnCase, async: true

  test "GET /health answers 200 with the Docker status", %{conn: conn} do
    conn = get(conn, "/health")

    assert %{"status" => "ok", "docker" => docker} = json_response(conn, 200)
    assert docker in ["reachable", "unreachable"]
  end

  test "HEAD /health answers 200 without a body", %{conn: conn} do
    conn = head(conn, "/health")

    assert conn.status == 200
    assert conn.resp_body == ""
  end

  test "other methods fall through to the router", %{conn: conn} do
    assert post(conn, "/health").status == 404
  end
end
