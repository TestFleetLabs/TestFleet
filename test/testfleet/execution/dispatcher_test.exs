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
         [
           engine: TestFleet.FakeEngine,
           ping: fn -> {:ok, "fake"} end,
           poll_interval: :timer.hours(1),
           max_concurrent_runs: 10
         ],
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

  test "a handler in the engine options replaces the recorder", context do
    queued(context, environment(context, 1))
    start_dispatcher(engine_opts: [handler: TestFleet.FlakyRecorder])

    assert_received {:engine_started, _request, opts}
    assert opts[:handler] == TestFleet.FlakyRecorder
  end

  describe "Docker check" do
    # Milestone 7, section 7: a fake ping the test switches.
    setup do
      docker = start_supervised!({Agent, fn -> {:error, %{message: "connection refused"}} end})
      TestFleet.Execution.subscribe_system()
      %{docker: docker, ping: fn -> Agent.get(docker, & &1) end}
    end

    defp docker_back(context), do: Agent.update(context.docker, fn _ -> {:ok, "1.44"} end)

    @tag :capture_log
    test "while Docker is unreachable, runs stay queued until it is back", context do
      run = queued(context, environment(context, 1))
      start_dispatcher(ping: context.ping, docker_check_interval: 0)

      assert started_ids() == []
      assert %{status: :queued} = Runs.get_run!(run.id)

      assert_received {:docker_status,
                       %{reachable: false, message: "connection refused", since: %DateTime{}}}

      assert %{reachable: false, message: "connection refused"} = Dispatcher.docker_status()

      docker_back(context)
      :ok = Dispatcher.dispatch()

      run_id = run.id
      assert_received {:engine_started, %{run_id: ^run_id}, _opts}
      assert_received {:docker_status, %{reachable: true, message: nil}}
      assert %{reachable: true} = Dispatcher.docker_status()
    end

    @tag :capture_log
    test "is checked at startup, and until it is back, also without queued runs", context do
      start_dispatcher(ping: context.ping, docker_check_interval: 0)
      assert_received {:docker_status, %{reachable: false}}

      docker_back(context)
      :ok = Dispatcher.dispatch()
      assert_received {:docker_status, %{reachable: true}}

      # Reachable and nothing queued: no more checks, no more messages.
      :ok = Dispatcher.dispatch()
      refute_received {:docker_status, _}
    end

    test "a reachable Docker is not announced", context do
      docker_back(context)
      start_dispatcher(ping: context.ping)

      refute_received {:docker_status, _}
      assert %{reachable: true, since: nil} = Dispatcher.docker_status()
    end

    test "a result is reused for the check interval", context do
      queued(context, environment(context, 1))
      test = self()

      ping = fn ->
        send(test, :pinged)
        {:ok, "1.44"}
      end

      # The run stays queued, so every pass would check.
      start_dispatcher(ping: ping, max_concurrent_runs: 0, docker_check_interval: :timer.hours(1))
      :ok = Dispatcher.dispatch()
      :ok = Dispatcher.dispatch()

      assert_received :pinged
      refute_received :pinged
    end

    @tag :capture_log
    test "the status is cleared when the dispatcher stops", context do
      start_dispatcher(ping: context.ping)
      assert %{reachable: false} = Dispatcher.docker_status()

      stop_supervised!(Dispatcher)
      assert %{reachable: true} = Dispatcher.docker_status()
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
