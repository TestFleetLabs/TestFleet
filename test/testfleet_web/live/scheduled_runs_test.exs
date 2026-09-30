defmodule TestFleetWeb.ScheduledRunsTest do
  use TestFleetWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Repo, Schedules, TestDefinitions}
  alias TestFleet.Runs.Run

  setup :register_and_log_in_user

  setup do
    project = project_fixture(%{name: "Customer Portal"})
    test_definition = test_definition_fixture(project: project)
    environment = environment_fixture(project: project)

    # Due since 2026-09-27 06:00 CEST (04:00 UTC).
    schedule =
      schedule_fixture(
        project: project,
        test_definition: test_definition,
        environment: environment,
        now: ~U[2026-09-27 00:00:00Z]
      )

    %{project: project, test_definition: test_definition, schedule: schedule}
  end

  defp tick, do: Schedules.tick(~U[2026-09-27 04:00:03Z])

  defp scheduled_run(schedule),
    do: Repo.one!(from r in Run, where: r.schedule_id == ^schedule.id)

  describe "schedule rows" do
    test "show the run the last tick created, live", %{conn: conn, schedule: schedule} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")
      refute has_element?(view, "#schedule-#{schedule.id}-last-tick")

      tick()
      run = scheduled_run(schedule)

      assert has_element?(view, "#schedule-#{schedule.id}-last-tick[data-outcome='created']")
      assert has_element?(view, "#schedule-#{schedule.id}-last-tick", "##{run.id}")
      assert has_element?(view, "#schedule-#{schedule.id}-last-tick [data-status='queued']")

      :ok = TestFleet.Runs.cancel_run(run)
      assert has_element?(view, "#schedule-#{schedule.id}-last-tick [data-status='cancelled']")
    end

    test "show a skip", %{conn: conn} = context do
      {:ok, _} =
        TestDefinitions.update_test_definition(context.test_definition, %{enabled: false})

      tick()

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      assert has_element?(
               view,
               "#schedule-#{context.schedule.id}-last-tick[data-outcome='skipped_disabled']",
               "test definition is disabled"
             )
    end
  end

  describe "run page" do
    test "shows the schedule and the slot", %{conn: conn, schedule: schedule} do
      tick()
      run = scheduled_run(schedule)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(
               view,
               "#run-schedule[href='/projects/customer-portal/schedules/#{schedule.id}/edit']",
               "0 6 * * *"
             )

      assert has_element?(view, "#run-scheduled-for", "06:00")
    end

    test "keeps the slot when the schedule was deleted", %{conn: conn, schedule: schedule} do
      tick()
      run = scheduled_run(schedule)
      {:ok, _} = Schedules.delete_schedule(schedule)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#run-schedule")
      assert has_element?(view, "#run-trigger", "Schedule")
      assert has_element?(view, "#run-scheduled-for")
    end

    test "a manual run shows no schedule", %{conn: conn} = context do
      run = TestFleet.RunsFixtures.run_fixture(test_definition: context.test_definition)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-trigger", "Manual")
      refute has_element?(view, "#run-scheduled-for")
    end
  end

  describe "dashboard" do
    test "marks a schedule the tick has not picked up as overdue", %{conn: conn} = context do
      upcoming =
        schedule_fixture(
          project: context.project,
          test_definition: context.test_definition,
          environment: environment_fixture(project: context.project)
        )

      {:ok, view, _html} = live(conn, ~p"/")

      # The setup's schedule was due in September 2026 and never ticked.
      assert has_element?(view, "#schedule-#{context.schedule.id}-overdue")
      refute has_element?(view, "#schedule-#{upcoming.id}-overdue")
    end
  end
end
