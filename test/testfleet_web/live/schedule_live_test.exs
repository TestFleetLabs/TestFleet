defmodule TestFleetWeb.ScheduleLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Schedules

  setup :register_and_log_in_user

  setup do
    %{project: project_fixture(%{name: "Customer Portal"})}
  end

  defp with_suite_and_environment(%{project: project}) do
    %{
      test_definition: test_definition_fixture(project: project, name: "Checkout"),
      environment: environment_fixture(project: project, name: "Production")
    }
  end

  describe "project page" do
    setup :with_suite_and_environment

    test "lists schedules with their next run", %{conn: conn} = context do
      schedule =
        schedule_fixture(
          project: context.project,
          test_definition: context.test_definition,
          environment: context.environment,
          cron_expression: "0 6 * * 1-5"
        )

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      row = "#schedules-#{schedule.id}"
      assert has_element?(view, row, "Checkout")
      assert has_element?(view, row, "Production")
      assert has_element?(view, row, "0 6 * * 1-5")

      assert has_element?(
               view,
               "#{row} time[datetime='#{DateTime.to_iso8601(schedule.next_run_at)}']"
             )

      assert has_element?(
               view,
               "#{row} a[href='/projects/customer-portal/schedules/#{schedule.id}/edit']"
             )
    end

    test "marks disabled schedules and other overlap policies", %{conn: conn} = context do
      schedule =
        schedule_fixture(
          project: context.project,
          test_definition: context.test_definition,
          environment: context.environment,
          enabled: false,
          overlap_policy: :queue
        )

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      assert has_element?(view, "#schedules-#{schedule.id}", "disabled")
      assert has_element?(view, "#schedules-#{schedule.id}", "queues overlaps")
      refute has_element?(view, "#schedules-#{schedule.id} time")
    end
  end

  describe "new" do
    test "explains what is missing before anything can be scheduled", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")

      assert has_element?(view, "#schedule-prerequisites")
      refute has_element?(view, "#schedule-form")

      test_definition_fixture(project: context.project, enabled: false)
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")
      assert has_element?(view, "#schedule-prerequisites a[href$='/test-definitions/new']")
      assert has_element?(view, "#schedule-prerequisites a[href$='/environments/new']")
    end

    test "creates a schedule", %{conn: conn, project: project} = context do
      %{test_definition: test_definition, environment: environment} =
        with_suite_and_environment(context)

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")

      # A single test definition and environment are preselected.
      assert has_element?(
               view,
               "#schedule_test_definition_id option[selected][value='#{test_definition.id}']"
             )

      assert has_element?(
               view,
               "#schedule_environment_id option[selected][value='#{environment.id}']"
             )

      assert has_element?(view, "#schedule_timezone option[selected][value='Europe/Vienna']")

      {:ok, show, _html} =
        view
        |> form("#schedule-form",
          schedule: %{
            cron_expression: "30 5 * * 1-5",
            timezone: "Europe/London",
            overlap_policy: "queue"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert [schedule] = Schedules.list_schedules(project)

      assert %{
               cron_expression: "30 5 * * 1-5",
               timezone: "Europe/London",
               overlap_policy: :queue,
               test_definition_id: test_definition_id,
               environment_id: environment_id
             } = schedule

      assert {test_definition_id, environment_id} == {test_definition.id, environment.id}
      assert has_element?(show, "#schedules-#{schedule.id}")
    end

    test "previews the next runs while typing", %{conn: conn} = context do
      with_suite_and_environment(context)
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")

      assert has_element?(view, "#schedule-preview-empty")

      view
      |> form("#schedule-form",
        schedule: %{cron_expression: "0 6 * * *", timezone: "Europe/Vienna"}
      )
      |> render_change()

      assert has_element?(view, "#schedule-preview-runs li", "06:00")
      assert has_element?(view, "#schedule-preview-2")
      refute has_element?(view, "#schedule-preview-3")

      view |> form("#schedule-form", schedule: %{cron_expression: "not cron"}) |> render_change()
      assert has_element?(view, "#schedule-preview-empty")
      assert has_element?(view, "#schedule_cron_expression.border-error")
    end

    test "a preset fills in the cron expression", %{conn: conn} = context do
      with_suite_and_environment(context)
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")

      view |> element("#cron-presets button", "Weekdays at 06:00") |> render_click()

      assert has_element?(view, "#schedule_cron_expression[value='0 6 * * 1-5']")
      assert has_element?(view, "#schedule-preview-0")
    end

    test "shows validation errors after a failed save",
         %{conn: conn, project: project} = context do
      with_suite_and_environment(context)
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/new")

      view |> form("#schedule-form", schedule: %{cron_expression: ""}) |> render_submit()

      assert has_element?(view, "#schedule_cron_expression.border-error")
      assert Schedules.list_schedules(project) == []
    end
  end

  describe "edit" do
    setup :with_suite_and_environment

    setup context do
      %{
        schedule:
          schedule_fixture(
            project: context.project,
            test_definition: context.test_definition,
            environment: context.environment
          )
      }
    end

    test "saves changes", %{conn: conn, project: project, schedule: schedule} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/#{schedule.id}/edit")

      {:ok, _show, _html} =
        view
        |> form("#schedule-form", schedule: %{cron_expression: "0 22 * * *", enabled: "false"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert %{cron_expression: "0 22 * * *", enabled: false} =
               Schedules.get_schedule!(project, schedule.id)
    end

    test "deletes the schedule", %{conn: conn, project: project, schedule: schedule} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/schedules/#{schedule.id}/edit")

      {:ok, _show, _html} =
        view
        |> element("#delete-schedule")
        |> render_click()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert Schedules.list_schedules(project) == []
    end

    test "a schedule of another project is not found", %{conn: conn} do
      other = schedule_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/projects/customer-portal/schedules/#{other.id}/edit")
      end
    end
  end

  test "the dashboard lists upcoming schedules", %{conn: conn} = context do
    %{test_definition: test_definition, environment: environment} =
      with_suite_and_environment(context)

    schedule =
      schedule_fixture(
        project: context.project,
        test_definition: test_definition,
        environment: environment
      )

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#upcoming-#{schedule.id}", "Checkout")
    assert has_element?(view, "#upcoming-#{schedule.id}", "Customer Portal")
    assert has_element?(view, "#upcoming-#{schedule.id} a[href='/projects/customer-portal']")
  end
end
