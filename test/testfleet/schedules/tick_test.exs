defmodule TestFleet.Schedules.TickTest do
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Repo, Runs, Schedules, TestDefinitions}
  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.{Schedule, TickWorker}

  # "0 6 * * *" in Europe/Vienna: 06:00 CEST is 04:00 UTC.
  @created ~U[2026-09-27 00:00:00Z]
  @slot ~U[2026-09-27 04:00:00Z]
  @next_slot ~U[2026-09-28 04:00:00Z]

  setup do
    project = project_fixture()

    %{
      project: project,
      test_definition: test_definition_fixture(project: project, image: "e2e:1.17"),
      environment: environment_fixture(project: project, max_concurrent_runs: 5)
    }
  end

  defp schedule(context, attrs \\ []) do
    schedule_fixture(
      [
        project: context.project,
        test_definition: context.test_definition,
        environment: context.environment,
        now: @created
      ] ++ attrs
    )
  end

  defp reload(schedule), do: Repo.get!(Schedule, schedule.id)

  defp runs_of(schedule),
    do: Repo.all(from r in Run, where: r.schedule_id == ^schedule.id, order_by: r.id)

  describe "a due schedule" do
    test "creates a queued run for its slot and moves on", context do
      schedule = schedule(context)
      assert schedule.next_run_at == @slot
      Runs.subscribe()

      assert [{schedule.id, :created}] == Schedules.tick(~U[2026-09-27 04:00:03Z])

      assert [run] = runs_of(schedule)

      assert %Run{
               trigger: :schedule,
               status: :queued,
               image: "e2e:1.17",
               scheduled_for: ~U[2026-09-27 04:00:00.000000Z],
               queued_at: ~U[2026-09-27 04:00:03.000000Z]
             } = run

      assert run.environment_id == context.environment.id

      assert %Schedule{
               next_run_at: @next_slot,
               last_tick_at: @slot,
               last_tick_outcome: :created,
               last_run_id: last_run_id,
               updated_at: updated_at
             } = reload(schedule)

      assert last_run_id == run.id
      assert updated_at == schedule.updated_at

      run_id = run.id
      assert_receive {:run_created, %Run{id: ^run_id}}
    end

    test "is ticked once, even if the tick runs again", context do
      schedule = schedule(context)
      now = ~U[2026-09-27 04:00:03Z]

      Schedules.tick(now)
      assert [] == Schedules.tick(now)
      assert [_] = runs_of(schedule)
    end

    test "an existing run for the slot counts as created", context do
      schedule = schedule(context)

      run_fixture(
        test_definition: context.test_definition,
        environment: context.environment,
        schedule_id: schedule.id,
        scheduled_for: ~U[2026-09-27 04:00:00.000000Z],
        # Finished, so the overlap policy does not skip first.
        status: :passed
      )

      assert [{_, :created}] = Schedules.tick(~U[2026-09-27 04:00:03Z])
      assert [_] = runs_of(schedule)
      assert %Schedule{next_run_at: @next_slot} = reload(schedule)
    end

    @tag :capture_log
    test "missed slots are coalesced into one run", context do
      schedule = schedule(context)

      assert [{_, :created}] = Schedules.tick(~U[2026-09-30 10:00:00Z])

      assert [%Run{scheduled_for: ~U[2026-09-27 04:00:00.000000Z]}] = runs_of(schedule)
      assert %Schedule{next_run_at: ~U[2026-10-01 04:00:00Z]} = reload(schedule)
    end
  end

  describe "schedules that do not run" do
    # The second tick is a day late on purpose: it logs the missed slot.
    @tag :capture_log
    test "not yet due, or disabled", context do
      due_later = schedule(context)
      disabled = schedule(context, cron_expression: "0 5 * * *", enabled: false)

      assert [] == Schedules.tick(~U[2026-09-27 03:59:59Z])
      assert [{due_later.id, :created}] == Schedules.tick(~U[2026-09-28 10:00:00Z])
      assert runs_of(disabled) == []
    end

    test "a disabled test definition skips, but the schedule moves on", context do
      schedule = schedule(context)

      {:ok, _} =
        TestDefinitions.update_test_definition(context.test_definition, %{enabled: false})

      assert [{_, :skipped_disabled}] = Schedules.tick(~U[2026-09-27 04:00:03Z])
      assert runs_of(schedule) == []

      assert %Schedule{
               next_run_at: @next_slot,
               last_tick_outcome: :skipped_disabled,
               enabled: true
             } =
               reload(schedule)
    end

    @tag :capture_log
    test "a broken schedule is disabled, the others still run", context do
      broken = schedule(context)
      healthy = schedule(context)

      Repo.update_all(from(s in Schedule, where: s.id == ^broken.id),
        set: [timezone: "Mars/Olympus_Mons"]
      )

      assert [{broken.id, :disabled}, {healthy.id, :created}] ==
               Schedules.tick(~U[2026-09-27 04:00:03Z]) |> Enum.sort()

      assert %Schedule{enabled: false} = reload(broken)
      assert [_] = runs_of(healthy)
    end
  end

  describe "overlap policy" do
    defp unfinished_run(context, schedule, status) do
      run_fixture(
        test_definition: context.test_definition,
        environment: context.environment,
        schedule_id: schedule.id,
        scheduled_for: ~U[2026-09-26 04:00:00.000000Z],
        status: status
      )
    end

    defp tick_outcome(schedule) do
      [{_, outcome}] =
        ~U[2026-09-27 04:00:03Z]
        |> Schedules.tick()
        |> Enum.filter(&(elem(&1, 0) == schedule.id))

      outcome
    end

    @tag :capture_log
    test "skip: no run while one is unfinished", context do
      for status <- [:queued, :preparing, :running] do
        schedule = schedule(context, overlap_policy: :skip)
        unfinished_run(context, schedule, status)

        assert tick_outcome(schedule) == :skipped_overlap

        assert %Schedule{last_tick_outcome: :skipped_overlap, next_run_at: @next_slot} =
                 reload(schedule)
      end
    end

    test "skip: manual runs do not count", context do
      schedule = schedule(context, overlap_policy: :skip)
      run_fixture(test_definition: context.test_definition, environment: context.environment)

      assert tick_outcome(schedule) == :created
    end

    test "skip: finished runs do not count", context do
      schedule = schedule(context, overlap_policy: :skip)
      unfinished_run(context, schedule, :failed)

      assert tick_outcome(schedule) == :created
    end

    @tag :capture_log
    test "queue: one run waits, no second", context do
      running = schedule(context, overlap_policy: :queue)
      unfinished_run(context, running, :running)
      assert tick_outcome(running) == :created

      waiting = schedule(context, overlap_policy: :queue)
      unfinished_run(context, waiting, :queued)
      assert tick_outcome(waiting) == :skipped_overlap
    end

    test "allow: always a run", context do
      schedule = schedule(context, overlap_policy: :allow)
      unfinished_run(context, schedule, :queued)

      assert tick_outcome(schedule) == :created
      assert length(runs_of(schedule)) == 2
    end
  end

  describe "daylight saving time" do
    # Europe/Vienna: 02:30 does not exist on 2027-03-28 and occurs twice on 2026-10-25.
    defp slots(context, created, days) do
      schedule =
        schedule(context, cron_expression: "30 2 * * *", overlap_policy: :allow, now: created)

      Enum.map(1..days, fn _ ->
        %Schedule{next_run_at: due} = reload(schedule)
        Schedules.tick(due)
        due
      end)
    end

    test "a time that does not exist runs at the end of the gap", context do
      assert slots(context, ~U[2027-03-26 12:00:00Z], 3) == [
               # 02:30 CET
               ~U[2027-03-27 01:30:00Z],
               # 03:00 CEST, right after the gap
               ~U[2027-03-28 01:00:00Z],
               # 02:30 CEST
               ~U[2027-03-29 00:30:00Z]
             ]
    end

    test "a time that occurs twice runs once", context do
      assert slots(context, ~U[2026-10-23 12:00:00Z], 3) == [
               # 02:30 CEST
               ~U[2026-10-24 00:30:00Z],
               # the first 02:30, still CEST
               ~U[2026-10-25 00:30:00Z],
               # 02:30 CET
               ~U[2026-10-26 01:30:00Z]
             ]
    end
  end

  describe "the worker" do
    @tag :capture_log
    test "ticks", context do
      schedule = schedule(context, now: ~U[2020-01-01 00:00:00Z])

      assert :ok = perform_job(TickWorker, %{})
      assert [%Run{trigger: :schedule}] = runs_of(schedule)
    end
  end
end
