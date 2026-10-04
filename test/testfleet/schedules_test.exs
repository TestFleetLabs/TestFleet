defmodule TestFleet.SchedulesTest do
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Environments, Schedules, TestDefinitions}
  alias TestFleet.Schedules.{Schedule, Timezones}

  @now ~U[2026-09-26 12:00:00Z]

  setup do
    project = project_fixture()

    %{
      project: project,
      test_definition: test_definition_fixture(project: project, name: "E2E"),
      environment: environment_fixture(project: project, name: "Production")
    }
  end

  defp attrs(%{test_definition: test_definition, environment: environment}, overrides \\ %{}) do
    Map.merge(
      %{
        test_definition_id: test_definition.id,
        environment_id: environment.id,
        cron_expression: "0 6 * * *",
        timezone: "Europe/Vienna"
      },
      overrides
    )
  end

  describe "create_schedule/3" do
    test "computes next_run_at in the schedule's time zone", %{project: project} = context do
      assert {:ok, schedule} = Schedules.create_schedule(project, attrs(context), now: @now)

      # The spec's example
      assert %Schedule{
               next_run_at: ~U[2026-09-27 04:00:00Z],
               overlap_policy: :skip,
               enabled: true
             } = schedule

      assert schedule.test_definition.name == "E2E"
      assert schedule.environment.name == "Production"
    end

    test "normalizes the cron expression", %{project: project} = context do
      {:ok, schedule} =
        Schedules.create_schedule(project, attrs(context, %{cron_expression: "  0   6 * * 1-5 "}))

      assert schedule.cron_expression == "0 6 * * 1-5"
    end

    test "validates the cron expression and the time zone", %{project: project} = context do
      for {overrides, field, message} <- [
            {%{cron_expression: "0 6 * *"}, :cron_expression,
             "needs five fields: minute hour day month weekday"},
            {%{cron_expression: "99 * * * *"}, :cron_expression,
             "is not a valid cron expression"},
            {%{cron_expression: "0 0 30 2 *"}, :cron_expression, "never matches a date"},
            {%{timezone: "Mars/Olympus_Mons"}, :timezone, "is not a known time zone"}
          ] do
        assert {:error, changeset} = Schedules.create_schedule(project, attrs(context, overrides))
        assert %{^field => [^message]} = errors_on(changeset), inspect(overrides)
      end
    end

    test "accepts time zone links such as UTC", %{project: project} = context do
      assert {:ok, _} = Schedules.create_schedule(project, attrs(context, %{timezone: "UTC"}))
    end

    test "test definition and environment must belong to the project",
         %{project: project} = context do
      other = project_fixture()

      for {overrides, field} <- [
            {%{test_definition_id: test_definition_fixture(project: other).id},
             :test_definition_id},
            {%{environment_id: environment_fixture(project: other).id}, :environment_id}
          ] do
        assert {:error, changeset} = Schedules.create_schedule(project, attrs(context, overrides))
        assert Map.has_key?(errors_on(changeset), field)
      end
    end

    test "a disabled test definition cannot be scheduled", %{project: project} = context do
      disabled = test_definition_fixture(project: project, enabled: false)

      assert {:error, changeset} =
               Schedules.create_schedule(
                 project,
                 attrs(context, %{test_definition_id: disabled.id})
               )

      assert %{test_definition_id: ["is not an enabled test definition of this project"]} =
               errors_on(changeset)
    end
  end

  describe "update_schedule/4" do
    setup %{project: project} = context do
      {:ok, schedule} = Schedules.create_schedule(project, attrs(context), now: @now)
      %{schedule: schedule}
    end

    @later ~U[2026-10-01 12:00:00Z]

    test "recomputes next_run_at when the cron expression or time zone changes",
         %{project: project, schedule: schedule} do
      {:ok, schedule} =
        Schedules.update_schedule(project, schedule, %{cron_expression: "0 7 * * *"}, now: @later)

      assert schedule.next_run_at == ~U[2026-10-02 05:00:00Z]

      {:ok, schedule} =
        Schedules.update_schedule(project, schedule, %{timezone: "Etc/UTC"}, now: @later)

      assert schedule.next_run_at == ~U[2026-10-02 07:00:00Z]
    end

    test "keeps next_run_at for other changes and while disabled",
         %{project: project, schedule: schedule} do
      {:ok, schedule} =
        Schedules.update_schedule(project, schedule, %{overlap_policy: "queue"}, now: @later)

      assert {schedule.overlap_policy, schedule.next_run_at} ==
               {:queue, ~U[2026-09-27 04:00:00Z]}

      {:ok, schedule} =
        Schedules.update_schedule(project, schedule, %{enabled: false}, now: @later)

      assert schedule.next_run_at == ~U[2026-09-27 04:00:00Z]
    end

    test "recomputes next_run_at when re-enabled", %{project: project, schedule: schedule} do
      {:ok, schedule} = Schedules.update_schedule(project, schedule, %{enabled: false})

      {:ok, schedule} =
        Schedules.update_schedule(project, schedule, %{enabled: true}, now: @later)

      assert schedule.next_run_at == ~U[2026-10-02 04:00:00Z]
    end

    test "still saves when its test definition was disabled later",
         %{project: project, schedule: schedule, test_definition: test_definition} do
      {:ok, _} = TestDefinitions.update_test_definition(test_definition, %{enabled: false})

      assert {:ok, %Schedule{overlap_policy: :allow}} =
               Schedules.update_schedule(project, schedule, %{overlap_policy: "allow"})
    end
  end

  test "list_schedules/1 lists the project's schedules, enabled first, soonest first",
       %{project: project} do
    later = schedule_fixture(project: project, cron_expression: "0 9 * * *", now: @now)
    sooner = schedule_fixture(project: project, cron_expression: "0 7 * * *", now: @now)
    disabled = schedule_fixture(project: project, cron_expression: "0 5 * * *", enabled: false)
    _elsewhere = schedule_fixture()

    assert project |> Schedules.list_schedules() |> Enum.map(& &1.id) ==
             [sooner.id, later.id, disabled.id]
  end

  test "list_upcoming/1 skips disabled schedules and test definitions", %{project: project} do
    first = schedule_fixture(project: project, cron_expression: "0 5 * * *", now: @now)
    second = schedule_fixture(cron_expression: "0 6 * * *", now: @now)
    schedule_fixture(project: project, enabled: false, now: @now)

    disabled_definition = test_definition_fixture(project: project)
    schedule_fixture(project: project, test_definition: disabled_definition, now: @now)
    TestDefinitions.update_test_definition(disabled_definition, %{enabled: false})

    upcoming = Schedules.list_upcoming(10)

    assert Enum.map(upcoming, & &1.id) == [first.id, second.id]
    assert hd(upcoming).test_definition.project.id == project.id
    assert [_] = Schedules.list_upcoming(1)
  end

  test "deleting the test definition or the environment deletes the schedule",
       %{project: project} = context do
    schedule =
      schedule_fixture(
        project: project,
        test_definition: context.test_definition,
        environment: context.environment
      )

    {:ok, _} = Environments.delete_environment(context.environment)
    refute Repo.get(Schedule, schedule.id)

    environment = environment_fixture(project: project)

    schedule =
      schedule_fixture(
        project: project,
        test_definition: context.test_definition,
        environment: environment
      )

    {:ok, _} = TestDefinitions.delete_test_definition(context.test_definition)
    refute Repo.get(Schedule, schedule.id)
  end

  test "preview/4 returns local run times, or nothing when invalid" do
    assert [first, second] = Schedules.preview("0 6 * * *", "Europe/Vienna", 2, @now)
    assert DateTime.to_naive(first) == ~N[2026-09-27 06:00:00]
    assert DateTime.to_naive(second) == ~N[2026-09-28 06:00:00]
    assert first.zone_abbr == "CEST"

    assert Schedules.preview("nope", "Europe/Vienna", 3, @now) == []
    assert Schedules.preview("0 6 * * *", "Nowhere", 3, @now) == []
    assert Schedules.preview(nil, nil, 3, @now) == []
  end

  test "the time zone list offers canonical zones" do
    zones = Timezones.list()

    assert "Europe/Vienna" in zones
    assert "Etc/UTC" in zones
    assert zones == Enum.sort(zones)
  end
end
