defmodule TestFleetWeb.StatisticsLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.ProjectsFixtures
  import TestFleet.TestDefinitionsFixtures

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "shows the organization's figures and the installation", %{conn: conn} do
      project = project_fixture()
      test_definition_fixture(project: project)

      {:ok, lv, _html} = live(conn, ~p"/#{org()}/statistics")

      assert has_element?(lv, "#stat-projects", "1")
      assert has_element?(lv, "#configuration-test-definitions", "1")
      assert has_element?(lv, "#largest-suites-empty")
      assert has_element?(lv, "#nav-statistics")

      # Docker may be there or not; either answer takes longer than the default 100 ms.
      render_async(lv, 5_000)
      assert has_element?(lv, "#database-tables")
      # Reachable or not, the Docker panel says which.
      assert has_element?(lv, "#images-usage") or has_element?(lv, "#images-unreachable")
    end

    test "refreshes", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/#{org()}/statistics")
      assert has_element?(lv, "#stat-projects", "0")

      project_fixture()
      lv |> element("#refresh-statistics") |> render_click()

      assert has_element?(lv, "#stat-projects", "1")
    end
  end

  describe "as a member" do
    setup :register_and_log_in_user

    test "is not available", %{conn: conn} do
      assert {:error, {:redirect, _}} = live(conn, ~p"/#{org()}/statistics")

      {:ok, lv, _html} = live(conn, ~p"/#{org()}")
      refute has_element?(lv, "#nav-statistics")
    end
  end
end
