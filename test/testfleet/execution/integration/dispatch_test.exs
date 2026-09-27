defmodule TestFleet.Execution.Integration.DispatchTest do
  # Milestone 3 end to end: Run now → dispatcher → RunExecution → Docker → recorded
  # status. Needs the spike registry with the fixture pushed (spike spec section 9).
  use TestFleet.DataCase, async: false

  import TestFleet.DockerCase,
    only: [ensure_docker!: 0, registry_image: 0, registry_auth: 0]

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RegistriesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Execution.{Dispatcher, RunExecution}
  alias TestFleet.Execution.Docker.Command
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  @moduletag :docker

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

    start_supervised!({Dispatcher, poll_interval: :timer.hours(1)})

    %{
      project: project,
      test_definition:
        test_definition_fixture(project: project, image: registry_image(), timeout_seconds: 60)
    }
  end

  defp run_now(context, mode, image \\ nil) do
    environment = environment_fixture(project: context.project, max_concurrent_runs: 1)
    variable_fixture(environment, %{key: "SPIKE_MODE", value: mode})

    test_definition =
      if image do
        {:ok, test_definition} =
          TestFleet.TestDefinitions.update_test_definition(context.test_definition, %{
            image: image
          })

        test_definition
      else
        context.test_definition
      end

    # All runs, before creating: the dispatcher may admit it before a per-run
    # subscription would be in place.
    Runs.subscribe()
    {:ok, run} = Runs.create_manual_run(test_definition, environment)
    on_exit(fn -> Command.remove(RunExecution.container_name(run.id)) end)
    run
  end

  # Returns the final run and every status it went through.
  defp await_finished(run_id, statuses \\ []) do
    receive do
      {:run_finished, %Run{id: ^run_id} = run} ->
        await_process_exit(run_id)
        {run, Enum.reverse([run.status | statuses]) |> Enum.dedup()}

      {_event, %Run{id: ^run_id, status: status}} ->
        await_finished(run_id, [status | statuses])
    after
      60_000 -> flunk("run #{run_id} did not finish")
    end
  end

  defp await_status(run_id, status) do
    receive do
      {_event, %Run{id: ^run_id, status: ^status}} -> :ok
      {_event, %Run{id: ^run_id}} -> await_status(run_id, status)
    after
      30_000 -> flunk("run #{run_id} did not reach #{status}")
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

  test "a passing suite from the private registry", context do
    run = run_now(context, "pass")

    assert {%Run{status: :passed} = finished, statuses} = await_finished(run.id)
    assert statuses == [:queued, :preparing, :running, :passed]

    assert %Run{
             exit_code: 0,
             oom_killed: false,
             error_message: nil,
             image_digest: "sha256:" <> _,
             container_id: container_id,
             started_at: %DateTime{},
             finished_at: %DateTime{}
           } = Runs.get_run!(finished.id)

    assert is_binary(container_id)
    assert {:error, %{status: 404}} = Command.inspect(RunExecution.container_name(run.id))
  end

  test "a failing suite", context do
    run = run_now(context, "fail")

    assert {%Run{status: :failed, exit_code: 1, error_message: nil}, _} = await_finished(run.id)
  end

  test "an image that does not exist is an error", context do
    run = run_now(context, "pass", "localhost:5055/does-not-exist:1")

    assert {%Run{status: :error, error_message: message, started_at: nil}, statuses} =
             await_finished(run.id)

    assert statuses == [:queued, :preparing, :error]
    assert is_binary(message)
  end

  test "cancelling a running suite", context do
    run = run_now(context, "hang")
    await_status(run.id, :running)

    assert :ok = Runs.cancel_run(Runs.get_run!(run.id))
    assert {%Run{status: :cancelled, finished_at: %DateTime{}}, _} = await_finished(run.id)
  end
end
