defmodule TestFleet.Execution do
  @moduledoc """
  Runs test suite containers (main spec sections 13–27).

  Each run is owned by one `TestFleet.Execution.RunExecution` process, registered by
  run id. Its events go to a `TestFleet.Execution.Handler` (`:handler`), or as
  `{:run_event, run_id, event}` messages to `:subscriber` (default: the caller); see
  `RunExecution`.
  """

  alias TestFleet.Execution.{Request, RunExecution}
  alias TestFleet.Execution.Docker.Command

  @doc """
  Starts a run and returns immediately.

  Options: `:handler` (a `TestFleet.Execution.Handler` module) or `:subscriber`.
  """
  def start(%Request{} = request, opts \\ []) do
    start_child(
      mode: :start,
      run_id: request.run_id,
      request: request,
      handler: opts[:handler],
      subscriber: Keyword.get(opts, :subscriber, self())
    )
  end

  @doc """
  Takes over the container of a run whose process is gone (main spec section 32).

  Options: `:handler`, `:subscriber`, `:artifact_path`, `:max_artifact_bytes`,
  `:last_log_timestamp` (nanoseconds of the last line already received),
  `:next_sequence`, and `cancel: true` to stop a running container right away, for a
  cancel that arrived while no process owned the run (Milestone 7, section 5).
  """
  def attach(run_id, opts \\ []) do
    start_child(
      mode: :attach,
      run_id: run_id,
      handler: opts[:handler],
      subscriber: Keyword.get(opts, :subscriber, self()),
      artifact_path: opts[:artifact_path],
      max_artifact_bytes: opts[:max_artifact_bytes],
      last_log_timestamp: opts[:last_log_timestamp],
      next_sequence: opts[:next_sequence],
      cancel: Keyword.get(opts, :cancel, false)
    )
  end

  @doc """
  How long preparing a run (network, image pull, inspect) may take, in milliseconds
  (`config :testfleet, TestFleet.Execution, pull_timeout: ...`, default 10 minutes).
  """
  def pull_timeout,
    do: Application.get_env(:testfleet, __MODULE__, [])[:pull_timeout] || :timer.minutes(10)

  @doc "Cancels a run. Idempotent: cancelling a finished or unknown run returns `:ok`."
  def cancel(run_id) do
    case Registry.lookup(TestFleet.Execution.Registry, run_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :cancel)
        catch
          # The run finished while we were asking.
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  @doc "Whether a `RunExecution` process owns the run right now."
  def executing?(run_id), do: Registry.lookup(TestFleet.Execution.Registry, run_id) != []

  @doc """
  TestFleet's containers, running or not. Each has `run_id`, `container_id`,
  `instance` (the `TestFleet.instance` label, `nil` on containers from before
  Milestone 7), `state` (Docker's, e.g. `"running"`), and `stop_grace_seconds`.
  Containers without a valid `TestFleet.run_id` label are left out.
  """
  def list_containers do
    with {:ok, containers} <- Command.list(["TestFleet=true"]) do
      containers =
        for %{"Labels" => labels} = container <- containers,
            {run_id, ""} <- [Integer.parse(labels["TestFleet.run_id"] || "")] do
          %{
            run_id: run_id,
            container_id: container["Id"],
            instance: labels["TestFleet.instance"],
            state: container["State"],
            stop_grace_seconds: grace_seconds(labels["TestFleet.stop_grace_seconds"])
          }
        end

      {:ok, containers}
    end
  end

  defp grace_seconds(label) do
    case Integer.parse(label || "") do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> 30
    end
  end

  @doc "Removes a container, running or not. Idempotent."
  def remove_container(container_id), do: Command.remove(container_id)

  @doc """
  Stops a container with its grace period (SIGTERM, then SIGKILL), then removes it.
  Blocks for up to the grace period. Idempotent.
  """
  def stop_and_remove_container(container_id, grace_seconds) do
    with :ok <- Command.stop(container_id, grace_seconds), do: Command.remove(container_id)
  end

  @doc """
  Runs to completion and returns the result with all log lines.

      {:ok, result} =
        TestFleet.Execution.run(%{
          image: "my-e2e-test:latest",
          command: ["./run-tests.sh"],
          environment: %{"BASE_URL" => "https://example.com"},
          timeout_seconds: 300
        })
  """
  def run(attrs) do
    request =
      case attrs do
        %Request{} = request ->
          request

        attrs ->
          attrs
          |> Map.new()
          |> Map.put_new_lazy(:run_id, fn -> System.unique_integer([:positive]) end)
          |> Request.new()
      end

    with {:ok, pid} <- start(request) do
      collect(request.run_id, Process.monitor(pid), [])
    end
  end

  defp collect(run_id, ref, logs) do
    receive do
      {:run_event, ^run_id, {:output, lines}} ->
        collect(run_id, ref, [lines | logs])

      {:run_event, ^run_id, {:finished, result}} ->
        Process.demonitor(ref, [:flush])
        {:ok, %{result | logs: logs |> Enum.reverse() |> Enum.concat()}}

      {:run_event, ^run_id, _event} ->
        collect(run_id, ref, logs)

      {:DOWN, ^ref, :process, _pid, reason} ->
        {:error, {:crashed, reason}}
    end
  end

  defp start_child(opts) do
    case DynamicSupervisor.start_child(TestFleet.Execution.Supervisor, {RunExecution, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_running}
      {:error, reason} -> {:error, reason}
    end
  end
end
