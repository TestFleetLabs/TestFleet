defmodule TestFleetWeb.DashboardLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs

  test "shows the run figures and empty lists", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    for id <- ~w(stat-running stat-passed-today stat-failed-today stat-timeouts-today) do
      assert has_element?(view, "#dashboard-stats ##{id}")
    end

    assert has_element?(view, "#recent-runs #recent-runs-empty-state")
    assert has_element?(view, "#queued-runs #queued-runs-empty-state")
    assert has_element?(view, "#upcoming-schedules #upcoming-schedules-empty")
  end

  describe "with runs" do
    setup do
      project = project_fixture()

      %{
        test_definition: test_definition_fixture(project: project),
        environment: environment_fixture(project: project, max_concurrent_runs: 20)
      }
    end

    defp run(context, attrs \\ []) do
      run_fixture(
        [test_definition: context.test_definition, environment: context.environment] ++ attrs
      )
    end

    test "counts active runs and today's results", %{conn: conn} = context do
      now = DateTime.utc_now()
      run(context, status: :running)
      run(context, status: :preparing)
      run(context, status: :failed, finished_at: now)
      run(context, status: :timeout, finished_at: now)
      run(context, status: :passed, finished_at: DateTime.add(now, -3, :day))

      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#stat-running", "2")
      assert has_element?(view, "#stat-passed-today", "0")
      assert has_element?(view, "#stat-failed-today", "1")
      assert has_element?(view, "#stat-timeouts-today", "1")
    end

    test "lists recent and queued runs and updates them live", %{conn: conn} = context do
      finished = run(context, status: :passed, finished_at: DateTime.utc_now())

      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "#recent-run-list #recent-#{finished.id}")
      refute has_element?(view, "#queued-run-list #queued-#{finished.id}")

      {:ok, run} = Runs.create_manual_run(context.test_definition, context.environment)
      assert has_element?(view, "#recent-run-list #recent-#{run.id}")
      assert has_element?(view, "#queued-run-list #queued-#{run.id}")

      {:ok, _} = Runs.mark_preparing(run)
      assert has_element?(view, "#recent-#{run.id} [data-status='preparing']")
      refute has_element?(view, "#queued-run-list #queued-#{run.id}")
      assert has_element?(view, "#stat-running", "1")
    end

    test "shows how many more runs are waiting", %{conn: conn} = context do
      runs = for _ <- 1..12, do: run(context)

      {:ok, view, _html} = live(conn, ~p"/")

      # The oldest wait longest and start first.
      assert has_element?(view, "#queued-#{hd(runs).id}")
      refute has_element?(view, "#queued-#{List.last(runs).id}")
      assert has_element?(view, "#queued-count", "12")
      assert has_element?(view, "#queued-more", "2 more")
    end
  end
end
