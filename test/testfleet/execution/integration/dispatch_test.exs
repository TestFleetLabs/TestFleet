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
  # Run processes may still write when a test ends (a Postgrex disconnect is logged),
  # and the scheduled run logs its coalesced slot. Shown if a test fails.
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

    start_supervised!({Dispatcher, poll_interval: :timer.hours(1)})

    %{
      project: project,
      test_definition:
        test_definition_fixture(project: project, image: registry_image(), timeout_seconds: 60)
    }
  end

  defp run_now(context, mode, image \\ nil, variables \\ []) do
    environment = environment_fixture(project: context.project, max_concurrent_runs: 1)
    variable_fixture(environment, %{key: "SPIKE_MODE", value: mode})
    for variable <- variables, do: variable_fixture(environment, variable)

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

  test "a failing JUnit suite stores its test results and artifacts", context do
    run = run_now(context, "junit_fail")

    assert {%Run{status: :failed, exit_code: 1} = finished, _} = await_finished(run.id)
    assert %{tests_passed: 1, tests_failed: 2, tests_skipped: 0, warnings: []} = finished

    assert [
             %{name: "pays", status: :failed, failure_message: "expected 200, got 500"},
             %{name: "crashes", status: :error},
             %{name: "adds", status: :passed, duration_ms: 1_000}
           ] = TestFleet.Results.list_test_results(finished)

    artifacts = TestFleet.Artifacts.list_artifacts(finished)
    assert Enum.map(artifacts, & &1.name) == ["junit.xml", "screenshots/checkout.png"]

    for artifact <- artifacts do
      path = TestFleet.Artifacts.Storage.path(artifact.storage_key)
      assert File.stat!(path).size == artifact.size_bytes
    end
  end

  test "an image that does not exist is an error", context do
    run = run_now(context, "pass", "localhost:5055/does-not-exist:1")

    assert {%Run{status: :error, error_message: message, started_at: nil}, statuses} =
             await_finished(run.id)

    assert statuses == [:queued, :preparing, :error]
    assert is_binary(message)
  end

  test "a due schedule runs through the same pipeline", context do
    environment = environment_fixture(project: context.project, max_concurrent_runs: 1)
    variable_fixture(environment, %{key: "SPIKE_MODE", value: "pass"})

    schedule =
      TestFleet.SchedulesFixtures.schedule_fixture(
        project: context.project,
        test_definition: context.test_definition,
        environment: environment,
        cron_expression: "* * * * *",
        now: DateTime.add(DateTime.utc_now(), -120, :second)
      )

    Runs.subscribe()
    assert [{_, :created}] = TestFleet.Schedules.tick(DateTime.utc_now())

    assert_receive {:run_created, %Run{trigger: :schedule, id: run_id}}, 5_000
    on_exit(fn -> Command.remove(RunExecution.container_name(run_id)) end)

    assert {%Run{status: :passed, schedule_id: schedule_id}, statuses} = await_finished(run_id)
    assert schedule_id == schedule.id
    assert statuses == [:preparing, :running, :passed]
  end

  test "output is stored and broadcast with secrets masked", context do
    secret = "s3cret-value-42"

    run =
      run_now(context, "secret", nil, [
        %{key: "SPIKE_SECRET", value: secret, secret: true},
        %{key: "SPIKE_PLAIN", value: "plain-value"}
      ])

    Runs.subscribe(run.id)
    assert {%Run{status: :passed}, _} = await_finished(run.id)

    lines = Runs.list_log_tail(run, 100)

    assert %{
             stdout: ["token=[MASKED] in the middle", "[MASKED]", "not secret: plain-value"],
             stderr: ["twice: [MASKED] [MASKED]"]
           } == Enum.group_by(lines, & &1.stream, & &1.content)

    assert Enum.map(lines, & &1.sequence) == [1, 2, 3, 4]
    assert %Run{last_log_sequence: 4, last_log_timestamp: timestamp} = Runs.get_run!(run.id)
    assert timestamp == lines |> Enum.map(& &1.timestamp) |> Enum.max()

    assert_received {:run_output, broadcast}
    refute Enum.any?(broadcast, &(&1.content =~ secret))
  end

  test "a chatty suite stores every line", context do
    run = run_now(context, "chatty")

    assert {%Run{status: :passed}, _} = await_finished(run.id)

    lines = Runs.list_log_tail(run, 200_000)
    assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..100_001)
    assert %Run{last_log_sequence: 100_001, log_truncated: false} = Runs.get_run!(run.id)
  end

  test "the log limit stops storing, not the run", context do
    previous = Application.get_env(:testfleet, Runs)
    Application.put_env(:testfleet, Runs, max_log_bytes: 1_000)
    on_exit(fn -> Application.put_env(:testfleet, Runs, previous) end)

    run = run_now(context, "chatty")
    assert {%Run{status: :passed}, _} = await_finished(run.id)

    assert %Run{log_truncated: true, log_bytes: bytes, last_log_sequence: 100_001} =
             Runs.get_run!(run.id)

    assert bytes <= 1_000
    stored = Runs.list_log_tail(run, 1_000)
    assert Enum.map(stored, & &1.sequence) == Enum.to_list(1..length(stored))
  end

  test "cancelling a running suite", context do
    run = run_now(context, "hang")
    await_status(run.id, :running)

    assert :ok = Runs.cancel_run(Runs.get_run!(run.id))
    assert {%Run{status: :cancelled, finished_at: %DateTime{}}, _} = await_finished(run.id)
  end
end
