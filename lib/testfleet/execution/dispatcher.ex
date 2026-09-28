defmodule TestFleet.Execution.Dispatcher do
  @moduledoc """
  Admits queued runs under the global and per-environment limits (main spec
  section 34, Milestone 3 section 5).

  A dispatch pass runs when a run is created or finished (PubSub on `runs`), and
  every `poll_interval` as a safety net. Active runs are counted in PostgreSQL, so
  the counts survive restarts. A run blocked by its environment does not block runs
  of other environments.

  The dispatcher is the bridge between runs and execution: it reads runs through
  `TestFleet.Runs`, and `RunExecution` never touches the database itself.

  Options (default from `config :testfleet, TestFleet.Execution.Dispatcher`):

    * `:max_concurrent_runs` - the global limit (default 10)
    * `:poll_interval` - milliseconds between safety-net passes (default 5000)
    * `:engine` - the module that starts executions (default `TestFleet.Execution`)
    * `:engine_opts` - extra options passed to `engine.start/2`
    * `:recover` - run a startup pass of `TestFleet.Execution.Reconciler` before the
      first dispatch (default true). It always works on the real Docker engine.
    * `:name` - the registered name (default `#{inspect(__MODULE__)}`)
  """
  use GenServer

  require Logger

  alias TestFleet.Execution.Reconciler
  alias TestFleet.Runs
  alias TestFleet.Runs.Recorder

  @defaults [
    max_concurrent_runs: 10,
    poll_interval: 5_000,
    engine: TestFleet.Execution,
    engine_opts: [],
    recover: true
  ]

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Runs a dispatch pass now and waits for it."
  def dispatch(server \\ __MODULE__), do: GenServer.call(server, :dispatch)

  @impl true
  def init(opts) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:testfleet, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Map.new()

    Runs.subscribe()
    schedule_poll(config)

    {:ok, config, {:continue, if(config.recover, do: :recover, else: :dispatch)}}
  end

  @impl true
  def handle_continue(:recover, state) do
    Reconciler.run(:startup)
    {:noreply, state, {:continue, :dispatch}}
  end

  def handle_continue(:dispatch, state) do
    dispatch_pass(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:dispatch, _from, state) do
    dispatch_pass(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({event, _run}, state) when event in [:run_created, :run_finished] do
    dispatch_pass(state)
    {:noreply, state}
  end

  def handle_info({:run_updated, _run}, state), do: {:noreply, state}

  def handle_info(:poll, state) do
    dispatch_pass(state)
    schedule_poll(state)
    {:noreply, state}
  end

  defp schedule_poll(%{poll_interval: interval}), do: Process.send_after(self(), :poll, interval)

  ## Dispatching

  defp dispatch_pass(state) do
    {total, by_environment} = Runs.active_counts()
    acc = {total, by_environment, Runs.active_schedule_ids()}

    Enum.reduce_while(Runs.list_queued(), acc, fn run, {total, counts, schedules} = acc ->
      environment_count = Map.get(counts, run.environment_id, 0)

      cond do
        total >= state.max_concurrent_runs ->
          {:halt, acc}

        environment_count >= run.environment.max_concurrent_runs ->
          {:cont, acc}

        waits_for_previous_run?(run, schedules) ->
          {:cont, acc}

        admit(run, state) == :started ->
          {:cont,
           {total + 1, Map.put(counts, run.environment_id, environment_count + 1),
            if(run.schedule_id, do: MapSet.put(schedules, run.schedule_id), else: schedules)}}

        true ->
          {:cont, acc}
      end
    end)

    :ok
  end

  # Under `queue`, a schedule's run starts only after its previous run finished,
  # even if the environment would allow both (Milestone 5, section 5).
  defp waits_for_previous_run?(%{schedule: %{overlap_policy: :queue, id: id}}, schedules),
    do: MapSet.member?(schedules, id)

  defp waits_for_previous_run?(_run, _schedules), do: false

  # The run is marked `preparing` before its process starts, so the counts include it
  # and no later pass can admit it twice.
  defp admit(run, state) do
    with {:ok, run} <- Runs.mark_preparing(run),
         {:ok, request} <- build_request(run),
         {:ok, _pid} <- state.engine.start(request, [handler: Recorder] ++ state.engine_opts) do
      :started
    else
      # Cancelled (or otherwise moved on) since it was loaded.
      :error ->
        :skipped

      {:error, reason} ->
        Logger.warning("run #{run.id}: cannot start: #{inspect(reason)}")
        Runs.fail(run.id, start_error(reason))
        :failed
    end
  end

  defp build_request(run) do
    {:ok, Runs.build_request(run)}
  rescue
    exception -> {:error, {:request, Exception.message(exception)}}
  end

  defp start_error({:request, message}), do: "could not prepare the run: #{message}"
  defp start_error(:already_running), do: "the run is already executing"
  defp start_error(reason), do: "could not start the execution: #{inspect(reason)}"
end
