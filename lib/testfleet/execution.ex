defmodule TestFleet.Execution do
  @moduledoc """
  Runs test suite containers (main spec sections 13–27).

  Each run is owned by one `TestFleet.Execution.RunExecution` process, registered by
  run id. Callers receive `{:run_event, run_id, event}` messages; see `RunExecution`.
  """

  alias TestFleet.Execution.{Request, RunExecution}

  @doc """
  Starts a run and returns immediately. Events go to `opts[:subscriber]` (default: the caller).
  """
  def start(%Request{} = request, opts \\ []) do
    start_child(
      mode: :start,
      run_id: request.run_id,
      request: request,
      subscriber: Keyword.get(opts, :subscriber, self())
    )
  end

  @doc """
  Takes over the container of a run whose process is gone (main spec section 32).

  Options: `:subscriber`, `:artifact_path`, `:last_log_timestamp` (nanoseconds of the
  last line already received) and `:next_sequence`.
  """
  def attach(run_id, opts \\ []) do
    start_child(
      mode: :attach,
      run_id: run_id,
      subscriber: Keyword.get(opts, :subscriber, self()),
      artifact_path: opts[:artifact_path],
      last_log_timestamp: opts[:last_log_timestamp],
      next_sequence: opts[:next_sequence]
    )
  end

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
