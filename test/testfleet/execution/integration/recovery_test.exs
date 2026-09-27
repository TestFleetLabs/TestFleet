defmodule TestFleet.Execution.Integration.RecoveryTest do
  # Startup recovery (Milestone 3, section 9) against real containers. A restart is
  # simulated by stopping the dispatcher and killing the run's process, which leaves
  # the container as a crash of TestFleet would.
  use TestFleet.DataCase, async: false

  import TestFleet.DockerCase,
    only: [ensure_docker!: 0, registry_image: 0, registry_auth: 0, kill_process: 1]

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RegistriesFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Execution
  alias TestFleet.Execution.{Dispatcher, RunExecution}
  alias TestFleet.Execution.Docker.Command
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  @moduletag :docker
  # Killing a run's process mid-query logs a Postgrex disconnect; recovery logs warnings.
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
  defp orphaned_run(context) do
    start_supervised!({Dispatcher, poll_interval: :timer.hours(1)})
    Runs.subscribe()
    {:ok, run} = Runs.create_manual_run(context.test_definition, context.environment)
    on_exit(fn -> Command.remove(RunExecution.container_name(run.id)) end)
    await_status(run.id, :running)

    stop_supervised!(Dispatcher)
    [{pid, _}] = Registry.lookup(TestFleet.Execution.Registry, run.id)
    kill_process(pid)
    await_unregistered(run.id)

    run
  end

  # A new dispatcher, as after a restart. `dispatch/1` returns after the recovery
  # and the first pass.
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

  # The Registry drops a dead process asynchronously; recovery skips runs that
  # still look executing.
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

    assert %Run{status: :error, error_message: "container disappeared", finished_at: %DateTime{}} =
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

    assert %Run{status: :error, error_message: "TestFleet restarted while preparing the run"} =
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
