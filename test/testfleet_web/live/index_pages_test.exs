defmodule TestFleetWeb.IndexPagesTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_admin

  test "projects shows its empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/projects")
    assert has_element?(view, "#projects #projects-empty")
  end

  test "runs shows its empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/runs")
    assert has_element?(view, "#runs #runs-empty")
  end

  test "registries shows its empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/registries")
    assert has_element?(view, "#registries #registries-empty")
  end
end
