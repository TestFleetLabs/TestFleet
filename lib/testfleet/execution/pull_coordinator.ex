defmodule TestFleet.Execution.PullCoordinator do
  @moduledoc """
  Runs at most one pull per image reference at a time.

  The first caller for a reference starts the pull; later callers for the same
  reference wait for it, and everyone gets the same result, including an error.
  Different references pull in parallel.

  A caller that goes away (its run's pull timeout, a cancel) only stops waiting.
  The pull goes on for the others; Docker cannot cancel a pull through the API
  anyway.

  The key is any term; `RunExecution` uses the reference as configured plus a hash of
  the credentials, so a pull with wrong credentials never answers one with the right
  ones.
  """
  use GenServer

  require Logger

  @task_supervisor TestFleet.Execution.TaskSupervisor

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `pull` (a zero-arity function) for `key`, or waits for the pull of `key`
  that is already running. Returns what `pull` returned.
  """
  def pull(key, pull, server \\ __MODULE__) when is_function(pull, 0) do
    GenServer.call(server, {:pull, key, pull}, :infinity)
  end

  @impl true
  def init(opts) do
    {:ok, %{task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor), pulls: %{}}}
  end

  @impl true
  def handle_call({:pull, key, pull}, from, state) do
    case state.pulls do
      %{^key => running} ->
        pulls = Map.put(state.pulls, key, %{running | waiters: [from | running.waiters]})
        {:noreply, %{state | pulls: pulls}}

      _ ->
        task = Task.Supervisor.async_nolink(state.task_supervisor, pull)
        running = %{ref: task.ref, waiters: [from]}
        {:noreply, %{state | pulls: Map.put(state.pulls, key, running)}}
    end
  end

  @impl true
  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(state, ref, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.error("image pull crashed: #{Exception.format_exit(reason)}")

    result =
      {:error, %{status: nil, message: "image pull crashed", reason: {:crashed, reason}}}

    {:noreply, finish(state, ref, result)}
  end

  defp finish(state, ref, result) do
    case Enum.find(state.pulls, fn {_key, running} -> running.ref == ref end) do
      {key, running} ->
        # A waiter that went away just does not get the reply.
        Enum.each(running.waiters, &GenServer.reply(&1, result))
        %{state | pulls: Map.delete(state.pulls, key)}

      nil ->
        state
    end
  end
end
