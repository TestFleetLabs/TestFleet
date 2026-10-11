defmodule TestFleetWeb.RunDeleteLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.RunsFixtures

  alias TestFleet.Runs

  describe "as an admin" do
    setup :register_and_log_in_admin

    test "deletes a finished run and returns to the runs list", %{conn: conn} do
      run = run_fixture(status: :passed)

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")

      {:ok, list, _html} =
        view
        |> element("#delete-run")
        |> render_click()
        |> follow_redirect(conn, ~p"/#{org()}/runs")

      assert Runs.get_run(run.id) == nil
      refute has_element?(list, "#runs-#{run.id}")
    end

    test "an unfinished run cannot be deleted", %{conn: conn} do
      run = run_fixture(status: :running)

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")
      refute has_element?(view, "#delete-run")
    end
  end

  describe "as a member" do
    setup :register_and_log_in_user

    test "there is no delete button, and the event is refused", %{conn: conn} do
      run = run_fixture(status: :passed)

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")
      refute has_element?(view, "#delete-run")

      render_click(view, "delete", %{})
      assert Runs.get_run(run.id)
    end

    test "a deleted run leaves the page and the lists showing it", %{conn: conn} do
      run = run_fixture(status: :failed)

      {:ok, list, _html} = live(conn, ~p"/#{org()}/runs")
      assert has_element?(list, "#runs-#{run.id}")

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")

      {:ok, _run} = Runs.delete_run(run)

      assert_redirect(view, ~p"/#{org()}/runs")
      refute has_element?(list, "#runs-#{run.id}")
    end
  end
end
