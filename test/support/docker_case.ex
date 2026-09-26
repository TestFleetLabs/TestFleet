defmodule TestFleet.DockerCase do
  @moduledoc """
  Integration tests against the real Docker Engine, through the socket proxy.

  Needs `docker compose --profile spike up -d` and the fixture images, see
  .specs/execution-spike-spec.md, section 9. Tagged `:docker` and excluded by default:

      mix test --only docker
  """

  use ExUnit.CaseTemplate

  alias TestFleet.Execution
  alias TestFleet.Execution.{Request, RunExecution}
  alias TestFleet.Execution.Docker.Command

  @fixture_image "testfleet/spike-suite:dev"
  @registry_image "localhost:5055/spike-suite:dev"
  @registry_auth %{username: "spike", password: "spike-password"}

  using do
    quote do
      import TestFleet.DockerCase

      alias TestFleet.Execution
      alias TestFleet.Execution.{Request, Result, RunExecution}
      alias TestFleet.Execution.Docker.Command

      @moduletag :docker
    end
  end

  setup_all do
    case Command.ping() do
      {:ok, _} ->
        :ok

      {:error, error} ->
        raise "Docker integration tests need the socket proxy (docker compose up -d): #{error.message}"
    end

    case Command.inspect_image(@fixture_image) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        raise "fixture image missing, run: docker build -t #{@fixture_image} test/support/fixtures/spike_suite"
    end

    :ok
  end

  def fixture_image, do: @fixture_image
  def registry_image, do: @registry_image
  def registry_auth, do: @registry_auth

  @doc "Run ids unique across test runs, so leftovers of an aborted run cannot collide."
  def run_id, do: System.os_time(:millisecond) * 1000 + System.unique_integer([:positive])

  def request(attrs \\ %{}) do
    %{
      run_id: run_id(),
      image: @fixture_image,
      pull_policy: :never,
      timeout_seconds: 60,
      stop_grace_seconds: 2
    }
    |> Map.merge(Map.new(attrs))
    |> Request.new()
  end

  @doc "Starts a run and removes its container when the test ends, whatever happened."
  def start_run!(attrs \\ %{}) do
    request = request(attrs)
    cleanup_container(request.run_id)
    {:ok, pid} = Execution.start(request)
    {request, pid}
  end

  def run!(attrs \\ %{}) do
    {request, _pid} = start_run!(attrs)
    await_finished(request.run_id)
  end

  def cleanup_container(run_id) do
    ExUnit.Callbacks.on_exit(fn -> Command.remove(RunExecution.container_name(run_id)) end)
  end

  # Output arrives in one batch per HTTP chunk; over a Unix socket that can be a
  # single line. Batches are therefore collected in reverse and flattened once:
  # appending with ++ would copy all lines received so far for every batch.

  @doc """
  Waits for the result. Returns `{result, lines}` with all output received meanwhile.
  `timeout` is the longest silence allowed between two events.
  """
  def await_finished(run_id, timeout \\ 30_000), do: await_finished(run_id, timeout, [])

  defp await_finished(run_id, timeout, batches) do
    receive do
      {:run_event, ^run_id, {:output, lines}} ->
        await_finished(run_id, timeout, [lines | batches])

      {:run_event, ^run_id, {:finished, result}} ->
        {result, flatten(batches)}

      {:run_event, ^run_id, _event} ->
        await_finished(run_id, timeout, batches)
    after
      timeout -> ExUnit.Assertions.flunk("run #{run_id}: no event for #{timeout} ms")
    end
  end

  @doc "Collects output until a line satisfies `fun`. Returns all lines so far."
  def await_output(run_id, fun, timeout \\ 15_000), do: await_output(run_id, fun, timeout, [])

  defp await_output(run_id, fun, timeout, batches) do
    receive do
      {:run_event, ^run_id, {:output, lines}} ->
        batches = [lines | batches]

        if Enum.any?(lines, fun),
          do: flatten(batches),
          else: await_output(run_id, fun, timeout, batches)

      {:run_event, ^run_id, {:finished, result}} ->
        ExUnit.Assertions.flunk("run #{run_id} finished early: #{inspect(result)}")

      {:run_event, ^run_id, _event} ->
        await_output(run_id, fun, timeout, batches)
    after
      timeout -> ExUnit.Assertions.flunk("run #{run_id}: expected output did not arrive")
    end
  end

  defp flatten(batches), do: batches |> Enum.reverse() |> Enum.concat()

  def await_event(run_id, pattern_fun, timeout \\ 15_000) do
    receive do
      {:run_event, ^run_id, event} ->
        if pattern_fun.(event), do: event, else: await_event(run_id, pattern_fun, timeout)
    after
      timeout -> ExUnit.Assertions.flunk("run #{run_id}: expected event did not arrive")
    end
  end

  def contents(lines), do: Enum.map(lines, & &1.content)

  def containers(run_id) do
    {:ok, containers} = Command.list(["TestFleet.run_id=#{run_id}"])
    containers
  end

  @doc "Kills a run's process like a crash would, leaving its container running."
  def kill_process(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  @doc """
  Attaches, retrying while the Registry has not yet dropped the killed process. The
  Registry cleans up asynchronously after the process exits.
  """
  def attach!(run_id, opts, attempts \\ 50) do
    case Execution.attach(run_id, opts) do
      {:ok, pid} ->
        pid

      {:error, :already_running} when attempts > 0 ->
        Process.sleep(10)
        attach!(run_id, opts, attempts - 1)
    end
  end
end
