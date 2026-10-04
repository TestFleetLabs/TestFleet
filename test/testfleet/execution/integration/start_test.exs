defmodule TestFleet.Execution.Integration.StartTest do
  # Start a container and decide its final status.
  use TestFleet.DockerCase, async: true

  test "the Docker Engine is reachable through the proxy" do
    assert {:ok, api_version} = Command.ping()
    assert api_version =~ ~r/^1\.\d+$/
  end

  test "the run network is created once and reused" do
    assert :ok = Command.ensure_network(RunExecution.network())
    assert :ok = Command.ensure_network(RunExecution.network())
  end

  test "exit code 0 passes and exit code 1 fails" do
    assert {%Result{status: :passed, exit_code: 0}, _} =
             run!(environment: %{"FIXTURE_MODE" => "pass"})

    assert {%Result{status: :failed, exit_code: 1}, _} =
             run!(environment: %{"FIXTURE_MODE" => "fail"})
  end

  test "the suite receives the reserved variables, which users cannot override" do
    {request, _pid} =
      start_run!(
        environment_name: "production",
        environment: %{"FIXTURE_MODE" => "env", "TestFleet_RUN_ID" => "spoofed"}
      )

    {%Result{status: :passed}, lines} = await_finished(request.run_id)

    assert contents(lines) == [
             "TestFleet_ARTIFACTS_DIR=/TestFleet/artifacts",
             "TestFleet_ENVIRONMENT=production",
             "TestFleet_RUN_ID=#{request.run_id}"
           ]
  end

  test "the container is hardened, limited, and isolated" do
    {request, _pid} =
      start_run!(
        environment: %{"FIXTURE_MODE" => "hang"},
        memory_limit: 256 * 1024 * 1024,
        cpu_limit: 0.5,
        project_id: 12
      )

    {:container_created, id} = await_event(request.run_id, &match?({:container_created, _}, &1))
    {:ok, info} = Command.inspect(id)

    assert info["Name"] == "/TestFleet-run-#{request.run_id}"
    assert info["Config"]["Tty"] == false

    assert %{"TestFleet" => "true", "TestFleet.project_id" => "12"} = info["Config"]["Labels"]
    assert info["Config"]["Labels"]["TestFleet.run_id"] == to_string(request.run_id)

    host_config = info["HostConfig"]
    assert host_config["CapDrop"] == ["ALL"]
    assert host_config["SecurityOpt"] == ["no-new-privileges"]
    assert host_config["Privileged"] == false
    assert host_config["AutoRemove"] == false
    assert host_config["Binds"] in [nil, []]
    assert host_config["NetworkMode"] == "TestFleet-runs"
    assert host_config["Memory"] == 256 * 1024 * 1024
    assert host_config["MemorySwap"] == 256 * 1024 * 1024
    assert host_config["NanoCpus"] == 500_000_000
    assert host_config["ShmSize"] == 2_147_483_648

    :ok = Execution.cancel(request.run_id)
    assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)
  end

  test "no container is left after a run" do
    {request, _pid} = start_run!(environment: %{"FIXTURE_MODE" => "pass"})
    assert {%Result{status: :passed}, _} = await_finished(request.run_id)
    assert containers(request.run_id) == []
  end

  test "a run id cannot be started twice while it runs" do
    {request, _pid} = start_run!(environment: %{"FIXTURE_MODE" => "hang"})
    assert {:error, :already_running} = Execution.start(request)

    :ok = Execution.cancel(request.run_id)
    assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)
  end

  test "an existing container is never started twice or removed by another execution" do
    {request, pid} = start_run!(environment: %{"FIXTURE_MODE" => "hang"})
    await_output(request.run_id, &(&1.content == "tick 1"))
    kill_process(pid)

    {:ok, _pid} = retry_start(request)
    {result, _} = await_finished(request.run_id)

    assert result.status == :error
    assert result.error_message == "container TestFleet-run-#{request.run_id} already exists"
    assert [%{"State" => "running"}] = containers(request.run_id)
  end

  test "an image that does not exist is an error" do
    {result, _} = run!(image: "testfleet/does-not-exist:nope")

    assert result.status == :error
    assert result.error_message =~ "No such image"
    assert result.started_at == nil
  end

  test "an invalid image reference is an error" do
    assert {%Result{status: :error, error_message: "invalid image reference" <> _}, _} =
             run!(image: "e2e:")
  end

  test "a suite over its memory limit is an error" do
    {result, _} = run!(environment: %{"FIXTURE_MODE" => "oom"}, memory_limit: 64 * 1024 * 1024)

    assert result.status == :error
    assert result.error_message == "memory limit exceeded"
    assert result.oom_killed
  end

  # The Registry drops the killed process asynchronously.
  defp retry_start(request, attempts \\ 50) do
    case Execution.start(request) do
      {:error, :already_running} when attempts > 0 ->
        Process.sleep(10)
        retry_start(request, attempts - 1)

      other ->
        other
    end
  end
end
