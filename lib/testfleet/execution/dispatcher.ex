defmodule TestFleet.Execution.Dispatcher do
  @moduledoc """
  Admits queued runs under the global and per-environment limits.

  A dispatch pass runs when a run is created or finished (PubSub on `runs`), and
  every `poll_interval` as a safety net. Active runs are counted in PostgreSQL, so
  the counts survive restarts. A run blocked by its environment does not block runs
  of other environments.

  The dispatcher is the bridge between runs and execution: it reads runs through
  `TestFleet.Runs`, and `RunExecution` never touches the database itself.

  While Docker is unreachable, nothing is admitted and runs stay `queued`.
  Docker is pinged before a pass that has queued runs, and on every pass while
  it is unreachable, at most once per `:docker_check_interval`.
  Changes are logged once and broadcast on the `system` topic as
  `{:docker_status, status}`; `docker_status/1` returns the current one.

  Options (default from `config :testfleet, TestFleet.Execution.Dispatcher`):

    * `:max_concurrent_runs` - the global limit (default 10)
    * `:poll_interval` - milliseconds between safety-net passes (default 5000)
    * `:engine` - the module that starts executions (default `TestFleet.Execution`)
    * `:engine_opts` - extra options passed to `engine.start/2`; a `:handler` here
      replaces the recorder
    * `:ping` - a zero-arity function checking Docker, returning `{:ok, _}` or
      `{:error, %{message: message}}` (default `TestFleet.Execution.ping/0`)
    * `:docker_check_interval` - how long a ping result is reused, in milliseconds
      (default 5000)
    * `:recover` - run a startup pass of `TestFleet.Execution.Reconciler` before the
      first dispatch (default true). It always works on the real Docker engine.
    * `:name` - the registered name (default `#{inspect(__MODULE__)}`)
  """
  use GenServer

  require Logger

  alias TestFleet.Execution
  alias TestFleet.Execution.Reconciler
  alias TestFleet.Runs
  alias TestFleet.Runs.Recorder

  @defaults [
    max_concurrent_runs: 10,
    poll_interval: 5_000,
    engine: TestFleet.Execution,
    engine_opts: [],
    ping: &TestFleet.Execution.ping/0,
    docker_check_interval: 5_000,
    recover: true
  ]

  @type docker_status :: %{
          reachable: boolean(),
          since: DateTime.t() | nil,
          message: String.t() | nil
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc "Runs a dispatch pass now and waits for it."
  def dispatch(server \\ __MODULE__), do: GenServer.call(server, :dispatch)

  @doc """
  Whether the dispatcher named `name` can reach Docker. Read without calling the
  process, so it never waits for a pass; reachable when no dispatcher runs.
  """
  @spec docker_status(atom()) :: docker_status()
  def docker_status(name \\ __MODULE__),
    do: :persistent_term.get({__MODULE__, name}, %{reachable: true, since: nil, message: nil})

  @impl true
  def init(opts) do
    # To clear the published Docker status on shutdown.
    Process.flag(:trap_exit, true)

    config =
      @defaults
      |> Keyword.merge(Application.get_env(:testfleet, __MODULE__, []))
      |> Keyword.merge(opts)
      |> Map.new()
      |> Map.merge(%{
        docker: %{reachable: true, since: nil, message: nil},
        docker_checked_at: nil
      })

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
    {:noreply, dispatch_pass(state)}
  end

  @impl true
  def handle_call(:dispatch, _from, state) do
    {:reply, :ok, dispatch_pass(state)}
  end

  @impl true
  def handle_info({event, _run}, state) when event in [:run_created, :run_finished] do
    {:noreply, dispatch_pass(state)}
  end

  def handle_info({:run_updated, _run}, state), do: {:noreply, state}

  def handle_info(:poll, state) do
    state = dispatch_pass(state)
    schedule_poll(state)
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    :persistent_term.erase({__MODULE__, state.name})
  end

  defp schedule_poll(%{poll_interval: interval}), do: Process.send_after(self(), :poll, interval)

  ## Docker

  # The first pass always checks, so an unreachable Docker shows up without waiting
  # for a queued run.
  defp check_docker(state, queued?) do
    due? = queued? or not state.docker.reachable or state.docker_checked_at == nil

    if due? and not fresh?(state) do
      state = %{state | docker_checked_at: System.monotonic_time(:millisecond)}

      case state.ping.() do
        {:ok, _} -> put_docker(state, true, nil)
        {:error, error} -> put_docker(state, false, error.message)
      end
    else
      state
    end
  end

  defp fresh?(%{docker_checked_at: nil}), do: false

  defp fresh?(state),
    do:
      System.monotonic_time(:millisecond) - state.docker_checked_at < state.docker_check_interval

  defp put_docker(%{docker: %{reachable: reachable}} = state, reachable, _message), do: state

  defp put_docker(state, reachable, message) do
    if reachable,
      do: Logger.info("Docker is reachable again; admitting queued runs"),
      else: Logger.warning("Docker is not reachable, queued runs wait: #{message}")

    status = %{reachable: reachable, since: DateTime.utc_now(), message: message}
    # Updated only on a change, so the cost of `:persistent_term.put/2` does not matter.
    :persistent_term.put({__MODULE__, state.name}, status)
    Execution.broadcast_docker_status(status)
    %{state | docker: status}
  end

  ## Dispatching

  defp dispatch_pass(state) do
    queued = Runs.list_queued()
    state = check_docker(state, queued != [])
    if queued != [] and state.docker.reachable, do: admit_queued(queued, state)
    state
  end

  defp admit_queued(queued, state) do
    {total, by_environment} = Runs.active_counts()
    acc = {total, by_environment, Runs.active_schedule_ids()}

    Enum.reduce_while(queued, acc, fn run, {total, counts, schedules} = acc ->
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
  # even if the environment would allow both.
  defp waits_for_previous_run?(%{schedule: %{overlap_policy: :queue, id: id}}, schedules),
    do: MapSet.member?(schedules, id)

  defp waits_for_previous_run?(_run, _schedules), do: false

  # The run is marked `preparing` before its process starts, so the counts include it
  # and no later pass can admit it twice.
  defp admit(run, state) do
    with {:ok, run} <- Runs.mark_preparing(run),
         {:ok, request} <- build_request(run),
         {:ok, _pid} <-
           state.engine.start(request, Keyword.merge([handler: Recorder], state.engine_opts)) do
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
