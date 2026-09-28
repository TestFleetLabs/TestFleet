defmodule TestFleet.Execution.Integration.ReconcilerTest do
  # The reconciler (Milestone 7, section 4) against real containers. A crash is
  # simulated by killing the run's process, which leaves the container as a crash
  # of TestFleet would. A restart additionally stops the dispatcher.
  #
  # Not async: a pass sees every container of this instance, and containers of runs
  # in other tests' sandboxes would look like orphans.
  use TestFleet.DataCase, async: false

  import TestFleet.DockerCase,
    only: [
      ensure_docker!: 0,
      fixture_image: 0,
      registry_image: 0,
      registry_auth: 0,
      kill_process: 1,
      run_id: 0
    ]

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RegistriesFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Artifacts
  alias TestFleet.Execution
  alias TestFleet.Execution.{Dispatcher, Reconciler, RunExecution}
  alias TestFleet.Execution.Docker.Command
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  @moduletag :docker
  # Killing a run's process mid-query logs a Postgrex disconnect; the reconciler
  # logs warnings.
  @moduletag :capture_log

  setup_all do
    ensure_docker!()
  end

  setup do
    project = project_fixture()

    registry_fixture(
      host: "localhost:5055",
      username: registry_auth().username,
      password: registry_auth().password
    )

    environment = environment_fixture(project: project, max_concurrent_runs: 1)
    variable_fixture(environment, %{key: "SPIKE_MODE", value: "hang"})

    %{
      environment: environment,
      test_definition:
        test_definition_fixture(project: project, image: registry_image(), timeout_seconds: 60)
    }
  end

  # A hanging suite whose process died: the container keeps running, and the run
  # stays `running` without anyone watching it.
  # With `output`, the process is killed only after that line was stored.
  defp orphaned_run(context, output \\ nil) do
    start_supervised!({Dispatcher, poll_interval: :timer.hours(1)})
    Runs.subscribe()
    {:ok, run} = Runs.create_manual_run(context.test_definition, context.environment)
    Runs.subscribe(run.id)
    on_exit(fn -> Command.remove(RunExecution.container_name(run.id)) end)
    await_status(run.id, :running)
    if output, do: await_output(run.id, output)

    stop_supervised!(Dispatcher)
    [{pid, _}] = Registry.lookup(TestFleet.Execution.Registry, run.id)
    kill_process(pid)
    await_unregistered(run.id)

    Runs.get_run!(run.id)
  end

  # A new dispatcher, as after a restart. `dispatch/1` returns after the startup
  # pass and the first dispatch.
  defp restart! do
    start_supervised!({Dispatcher, poll_interval: :timer.hours(1), recover: true})
    :ok = Dispatcher.dispatch()
  end

  defp await_status(run_id, status) do
    receive do
      {_event, %Run{id: ^run_id, status: ^status}} -> :ok
      {_event, %Run{id: ^run_id}} -> await_status(run_id, status)
    after
      30_000 -> flunk("run #{run_id} did not reach #{status}")
    end
  end

  # `{:run_output, _}` is broadcast after the batch is stored.
  defp await_output(run_id, content) do
    receive do
      {:run_output, lines} ->
        if Enum.any?(lines, &(&1.content == content)),
          do: :ok,
          else: await_output(run_id, content)
    after
      30_000 -> flunk("run #{run_id}: #{inspect(content)} did not arrive")
    end
  end

  defp await_finished(run_id) do
    receive do
      {:run_finished, %Run{id: ^run_id} = run} ->
        await_process_exit(run_id)
        run

      {_event, %Run{id: ^run_id}} ->
        await_finished(run_id)
    after
      60_000 -> flunk("run #{run_id} did not finish")
    end
  end

  # The container is removed after the final status is recorded.
  defp await_process_exit(run_id) do
    case Registry.lookup(TestFleet.Execution.Registry, run_id) do
      [{pid, _}] ->
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 30_000

      [] ->
        :ok
    end
  end

  # The Registry drops a dead process asynchronously; the reconciler skips runs
  # that still look executing.
  defp await_unregistered(run_id, attempts \\ 50) do
    cond do
      not Execution.executing?(run_id) ->
        :ok

      attempts > 0 ->
        Process.sleep(10)
        await_unregistered(run_id, attempts - 1)

      true ->
        flunk("run #{run_id} is still registered")
    end
  end

  # Orphans are stopped and removed in a task, after the pass returned.
  defp await_removed(container_id, attempts \\ 100) do
    case Command.inspect(container_id) do
      {:error, %{status: 404}} ->
        :ok

      {:ok, _} when attempts > 0 ->
        Process.sleep(50)
        await_removed(container_id, attempts - 1)

      {:ok, _} ->
        flunk("container #{container_id} was not removed")
    end
  end

  # A hanging container with TestFleet's labels, but no run in this database.
  defp foreign_container(labels) do
    run_id = run_id()

    labels =
      Map.merge(
        %{
          "TestFleet" => "true",
          "TestFleet.run_id" => to_string(run_id),
          "TestFleet.stop_grace_seconds" => "1"
        },
        labels
      )

    spec = %{
      "Image" => fixture_image(),
      # `tick` needs none of the variables TestFleet sets; `hang` does.
      "Env" => ["SPIKE_MODE=tick", "SPIKE_TICKS=600"],
      "Labels" => labels,
      "HostConfig" => %{"AutoRemove" => false}
    }

    {:ok, id} = Command.create("TestFleet-test-orphan-#{run_id}", spec)
    :ok = Command.start(id)
    on_exit(fn -> Command.remove(id) end)
    id
  end

  describe "at startup" do
    test "reattaches to a suite that is still running", context do
      run = orphaned_run(context)

      restart!()

      assert Execution.executing?(run.id)
      assert %Run{status: :running} = Runs.get_run!(run.id)

      # The new process owns the container: cancelling stops it.
      :ok = Runs.cancel_run(Runs.get_run!(run.id))
      assert %Run{status: :cancelled} = await_finished(run.id)
      assert {:error, %{status: 404}} = Command.inspect(RunExecution.container_name(run.id))
    end

    test "the stored log continues without gaps or duplicates", context do
      run = orphaned_run(context, "tick 2")
      # The suite keeps ticking while nothing is attached.
      Process.sleep(2_000)

      restart!()
      await_output(run.id, "tick 6")

      :ok = Runs.cancel_run(Runs.get_run!(run.id))
      assert %Run{status: :cancelled} = await_finished(run.id)

      lines = Runs.list_log_tail(run, 1_000)
      ticks = lines |> Enum.map(& &1.content) |> Enum.filter(&String.starts_with?(&1, "tick "))

      assert ticks == Enum.map(1..length(ticks), &"tick #{&1}")
      assert length(ticks) >= 6
      assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..length(lines))
    end

    test "finishes a suite that exited while TestFleet was down", context do
      run = orphaned_run(context)
      :ok = Command.stop(RunExecution.container_name(run.id), 2)

      restart!()

      assert %Run{status: :failed, exit_code: 143, finished_at: %DateTime{}} =
               await_finished(run.id)

      assert {:error, %{status: 404}} = Command.inspect(RunExecution.container_name(run.id))
    end

    test "a running suite whose container disappeared is an error", context do
      run = orphaned_run(context)
      :ok = Command.remove(RunExecution.container_name(run.id))

      restart!()

      assert %Run{
               status: :error,
               error_message: "container disappeared",
               finished_at: %DateTime{}
             } =
               Runs.get_run!(run.id)
    end

    test "a run left preparing without a container is an error", context do
      run =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.environment,
          status: :preparing
        )

      restart!()

      assert %Run{status: :error, error_message: "TestFleet lost the run while preparing it"} =
               Runs.get_run!(run.id)
    end

    test "removes the leftover container of a finished run", context do
      run = orphaned_run(context)
      {:ok, _} = Runs.fail(run.id, "finished before the container was removed")

      restart!()

      assert {:error, %{status: 404}} = Command.inspect(RunExecution.container_name(run.id))
      assert %Run{status: :error} = Runs.get_run!(run.id)
    end
  end

  describe "periodically" do
    test "reattaches a run whose process crashed, without a restart", context do
      run = orphaned_run(context, "tick 1")

      start_supervised!({Reconciler, interval: 100})
      await_output(run.id, "tick 3")

      assert Execution.executing?(run.id)
      :ok = Runs.cancel_run(Runs.get_run!(run.id))
      assert %Run{status: :cancelled} = await_finished(run.id)
    end

    test "a cancel while no process owns the run stops the container and keeps artifacts",
         context do
      run = orphaned_run(context)

      :ok = Runs.cancel_run(run)
      assert %Run{status: :running, cancel_requested_at: %DateTime{}} = Runs.get_run!(run.id)

      assert [{:attach, %Run{id: id}, true}] = Reconciler.run(:periodic)
      assert id == run.id

      assert %Run{status: :cancelled} = finished = await_finished(run.id)
      assert {:error, %{status: 404}} = Command.inspect(RunExecution.container_name(run.id))
      assert Enum.any?(Artifacts.list_artifacts(finished), &(&1.name == "summary.txt"))
    end

    test "a cancelled preparing run without a container ends cancelled", context do
      run =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.environment,
          status: :preparing
        )

      :ok = Runs.cancel_run(run)
      assert [{:mark_cancelled, _}] = Reconciler.run(:periodic)
      assert %Run{status: :cancelled, finished_at: %DateTime{}} = Runs.get_run!(run.id)
    end

    test "a preparing run is given a minute before it counts as lost", context do
      run =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.environment,
          status: :preparing
        )

      assert Reconciler.run(:periodic) == []
      assert %Run{status: :preparing} = Runs.get_run!(run.id)
    end
  end

  describe "database failure" do
    # Milestone 7, section 7: the recorder raises, the process crashes with its
    # container running, and the next pass reattaches.
    setup do
      on_exit(&TestFleet.FlakyRecorder.disarm/0)
    end

    test "a failed write crashes the process; the next pass resumes the log in full",
         context do
      TestFleet.FlakyRecorder.arm()

      start_supervised!(
        {Dispatcher,
         poll_interval: :timer.hours(1), engine_opts: [handler: TestFleet.FlakyRecorder]}
      )

      Runs.subscribe()
      {:ok, run} = Runs.create_manual_run(context.test_definition, context.environment)
      Runs.subscribe(run.id)
      on_exit(fn -> Command.remove(RunExecution.container_name(run.id)) end)

      await_status(run.id, :running)
      [{pid, _}] = Registry.lookup(TestFleet.Execution.Registry, run.id)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, {%DBConnection.ConnectionError{}, _}}, 15_000
      await_unregistered(run.id)

      # The failed batch was never stored, and the suite keeps running.
      assert %Run{status: :running, last_log_sequence: 0} = Runs.get_run!(run.id)

      assert {:ok, %{"State" => %{"Running" => true}}} =
               Command.inspect(RunExecution.container_name(run.id))

      assert [{:attach, %Run{}, false}] = Reconciler.run(:periodic)
      await_output(run.id, "tick 3")

      :ok = Runs.cancel_run(Runs.get_run!(run.id))
      assert %Run{status: :cancelled} = await_finished(run.id)

      lines = Runs.list_log_tail(run, 1_000)
      ticks = lines |> Enum.map(& &1.content) |> Enum.filter(&String.starts_with?(&1, "tick "))

      assert ["tick 1", "tick 2", "tick 3" | _] = ticks
      assert ticks == Enum.map(1..length(ticks), &"tick #{&1}")
      assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..length(lines))
    end
  end

  describe "orphans" do
    test "a container of this instance without a run is stopped and removed" do
      id = foreign_container(%{"TestFleet.instance" => TestFleet.Instance.id()})

      assert [{:remove_orphan, %{container_id: ^id}}] = Reconciler.run(:periodic)
      await_removed(id)
    end

    test "containers of another instance, or from before instances, are left alone" do
      other = foreign_container(%{"TestFleet.instance" => Ecto.UUID.generate()})
      legacy = foreign_container(%{})

      assert Reconciler.run(:periodic) == []
      assert {:ok, %{"State" => %{"Running" => true}}} = Command.inspect(other)
      assert {:ok, %{"State" => %{"Running" => true}}} = Command.inspect(legacy)
    end

    test "new runs carry this instance's label", context do
      run = orphaned_run(context)

      assert {:ok, %{"Config" => %{"Labels" => labels}}} =
               Command.inspect(RunExecution.container_name(run.id))

      assert labels["TestFleet.instance"] == TestFleet.Instance.id()
    end
  end
end
