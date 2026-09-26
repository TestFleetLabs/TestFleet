defmodule TestFleetWeb.DashboardLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "shows the run figures and empty lists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <- ~w(stat-running stat-passed-today stat-failed-today stat-timeouts) do
      assert has_element?(view, "#dashboard-stats ##{id}")
    end

    assert has_element?(view, "#recent-runs #recent-runs-empty")
    assert has_element?(view, "#upcoming-schedules #upcoming-schedules-empty")
  end
end
