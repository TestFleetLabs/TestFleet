defmodule TestFleet.Execution.DispatcherTest do
  # The dispatcher is its own process and needs the shared sandbox.
  use TestFleet.DataCase, async: false

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Execution.Dispatcher
  alias TestFleet.Runs
  alias TestFleet.Runs.Recorder

  setup do
    project = project_fixture()
    %{project: project, test_definition: test_definition_fixture(project: project)}
  end

  defp start_dispatcher(opts \\ []) do
    engine_opts = Keyword.merge([test_pid: self()], Keyword.get(opts, :engine_opts, []))

    start_supervised!(
      {Dispatcher,
       Keyword.merge(
         [engine: TestFleet.FakeEngine, poll_interval: :timer.hours(1), max_concurrent_runs: 10],
         Keyword.put(opts, :engine_opts, engine_opts)
       )}
    )

    # The first pass runs in handle_continue; this waits for it.
    :ok = Dispatcher.dispatch()
  end

  defp environment(context, limit),
    do: environment_fixture(project: context.project, max_concurrent_runs: limit)

  defp queued(context, environment),
    do: run_fixture(test_definition: context.test_definition, environment: environment)

  defp started_ids do
    receive do
      {:engine_started, request, _opts} -> [request.run_id | started_ids()]
    after
      0 -> []
    end
  end

  test "admits a queued run and starts it with the recorder", context do
    run = queued(context, environment(context, 1))
    start_dispatcher()

    run_id = run.id
    assert_received {:engine_started, %{run_id: ^run_id}, opts}
    assert opts[:handler] == Recorder
    assert %{status: :preparing} = Runs.get_run!(run.id)
  end

  test "respects the environment limit and admits the next run when one finishes", context do
    environment = environment(context, 1)
    first = queued(context, environment)
    second = queued(context, environment)

    start_dispatcher()
    assert started_ids() == [first.id]
    assert %{status: :queued} = Runs.get_run!(second.id)

    {:ok, _} = Runs.fail(first.id, "gone")
    :ok = Dispatcher.dispatch()

    second_id = second.id
    assert_received {:engine_started, %{run_id: ^second_id}, _opts}
  end

  test "counts runs that are already active", context do
    environment = environment(context, 1)

    _running =
      run_fixture(
        test_definition: context.test_definition,
        environment: environment,
        status: :running
      )

    queued = queued(context, environment)

    start_dispatcher()
    assert started_ids() == []
    assert %{status: :queued} = Runs.get_run!(queued.id)
  end

  test "respects the global limit, oldest first", context do
    runs = for _ <- 1..3, do: queued(context, environment(context, 5))

    start_dispatcher(max_concurrent_runs: 2)
    assert Enum.sort(started_ids()) == runs |> Enum.take(2) |> Enum.map(& &1.id)
  end

  test "a blocked environment does not block other environments", context do
    busy = environment(context, 1)
    free = environment(context, 1)
    first = queued(context, busy)
    _waiting = queued(context, busy)
    other = queued(context, free)

    start_dispatcher()
    assert Enum.sort(started_ids()) == [first.id, other.id]
  end

  test "skips a run cancelled before admission", context do
    run = queued(context, environment(context, 1))
    :ok = Runs.cancel_run(run)

    start_dispatcher()
    assert started_ids() == []
    assert %{status: :cancelled} = Runs.get_run!(run.id)
  end

  @tag :capture_log
  test "a run that cannot start ends as error", context do
    run = queued(context, environment(context, 1))

    start_dispatcher(engine_opts: [result: {:error, :docker_down}])

    assert %{status: :error, error_message: message, finished_at: %DateTime{}} =
             Runs.get_run!(run.id)

    assert message =~ "docker_down"
  end

  describe "a schedule's runs" do
    defp scheduled_run(context, schedule, attrs) do
      run_fixture(
        [
          test_definition: context.test_definition,
          environment: schedule.environment,
          schedule_id: schedule.id,
          scheduled_for: DateTime.utc_now()
        ] ++ attrs
      )
    end

    defp schedule(context, policy) do
      TestFleet.SchedulesFixtures.schedule_fixture(
        project: context.project,
        test_definition: context.test_definition,
        environment: environment(context, 5),
        overlap_policy: policy
      )
    end

    test "under queue, a run waits for its schedule's previous run", context do
      schedule = schedule(context, :queue)
      previous = scheduled_run(context, schedule, status: :running)
      waiting = scheduled_run(context, schedule, [])
      other = queued(context, schedule.environment)

      start_dispatcher()
      # Waiting does not block other runs.
      assert started_ids() == [other.id]
      assert %{status: :queued} = Runs.get_run!(waiting.id)

      {:ok, _} = Runs.fail(previous.id, "done")
      :ok = Dispatcher.dispatch()

      waiting_id = waiting.id
      assert_received {:engine_started, %{run_id: ^waiting_id}, _opts}
    end

    test "under allow, runs of a schedule run in parallel", context do
      schedule = schedule(context, :allow)
      scheduled_run(context, schedule, status: :running)
      parallel = scheduled_run(context, schedule, [])

      start_dispatcher()
      assert started_ids() == [parallel.id]
    end
  end

  test "wakes up when a run is created", context do
    environment = environment(context, 1)
    start_dispatcher()

    {:ok, run} = Runs.create_manual_run(context.test_definition, environment)

    run_id = run.id
    assert_receive {:engine_started, %{run_id: ^run_id}, _opts}
  end
end
