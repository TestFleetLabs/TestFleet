defmodule TestFleet.Execution.Reconciler do
  @moduledoc """
  Compares runs in PostgreSQL with TestFleet's containers in Docker and repairs the
  difference.

  A pass runs at startup (by the dispatcher, before its first dispatch) and every
  `:interval` milliseconds (this process, default 30 s). First matching rule wins;
  "process" means a `RunExecution` registered for the run.

  | # | Run                      | Process | Container     | Action                        |
  |---|--------------------------|---------|---------------|-------------------------------|
  | 1 | active                   | yes     | any           | re-send a requested cancel    |
  | 2 | active, cancel requested | no      | present       | attach with `cancel: true`    |
  | 3 | active                   | no      | present       | attach                        |
  | 4 | active, cancel requested | no      | missing       | finalize `cancelled`          |
  | 5 | `preparing`              | no      | missing       | finalize `error` (after 60 s) |
  | 6 | `running`                | no      | missing       | finalize `error`              |
  | 7 | final                    | no      | present       | remove the container          |
  | 8 | no run row               | –       | this instance | stop and remove (orphan)      |
  | 9 | no run row               | –       | other / none  | nothing                       |

  Only containers of this instance (`TestFleet.instance`) and containers without an
  instance label are matched to runs; the latter are never removed
  as orphans. Without an answer from Docker, nothing is changed.

  Options (default from `config :testfleet, #{inspect(__MODULE__)}`): `:interval`,
  and `:enabled` (`false` makes `start_link/1` return `:ignore`).
  """
  use GenServer

  require Logger

  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.Storage
  alias TestFleet.Execution
  alias TestFleet.Runs
  alias TestFleet.Runs.{Recorder, Run}

  @defaults [interval: 30_000, enabled: true]
  # The dispatcher marks a run `preparing` a moment before its process registers.
  @preparing_grace_seconds 60

  @lost_while_preparing "TestFleet lost the run while preparing it"
  @container_disappeared "container disappeared"

  ## Process

  def start_link(opts \\ []) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:testfleet, __MODULE__, []))
      |> Keyword.merge(opts)

    if config[:enabled],
      do: GenServer.start_link(__MODULE__, config, name: Keyword.get(opts, :name, __MODULE__)),
      else: :ignore
  end

  @impl true
  def init(config) do
    schedule(config[:interval])
    {:ok, Map.new(config)}
  end

  @impl true
  def handle_info(:reconcile, state) do
    run(:periodic)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :reconcile, interval)

  ## Pass

  @doc """
  Runs one pass. `mode` is `:startup` (no process can exist yet, so no grace for
  `preparing` runs) or `:periodic`. Returns the actions taken, or `:skipped` when
  Docker cannot be reached.
  """
  def run(mode \\ :periodic) when mode in [:startup, :periodic] do
    case Execution.list_containers() do
      {:ok, containers} ->
        containers
        |> input()
        |> plan(mode)
        |> Enum.map(&execute/1)

      {:error, error} ->
        Logger.warning("reconciliation skipped, Docker is not reachable: #{error.message}")
        :skipped
    end
  end

  defp input(containers) do
    instance = TestFleet.Instance.id()
    # Other instances' containers are not ours to judge.
    containers = Enum.filter(containers, &(&1.instance in [instance, nil]))
    active_runs = Runs.list_active()
    container_run_ids = Enum.map(containers, & &1.run_id)

    %{
      instance: instance,
      now: DateTime.utc_now(),
      active_runs: active_runs,
      containers: containers,
      executing:
        MapSet.new(
          for id <- Enum.map(active_runs, & &1.id) ++ container_run_ids,
              Execution.executing?(id),
              do: id
        ),
      existing_run_ids: MapSet.new(Runs.existing_run_ids(container_run_ids)),
      final_run_ids: MapSet.new(Runs.final_run_ids(container_run_ids))
    }
  end

  @doc """
  Decides what to do, without side effects. `input` has `:instance`, `:now`,
  `:active_runs`, `:containers` (as from `Execution.list_containers/0`, already
  limited to this instance and legacy ones), and the sets `:executing`,
  `:existing_run_ids`, and `:final_run_ids`.
  """
  def plan(input, mode) do
    by_run_id = Map.new(input.containers, &{&1.run_id, &1})

    runs =
      Enum.flat_map(input.active_runs, fn run ->
        plan_run(run, by_run_id[run.id], MapSet.member?(input.executing, run.id), input, mode)
      end)

    containers =
      Enum.flat_map(input.containers, fn container ->
        plan_container(container, input)
      end)

    runs ++ containers
  end

  defp plan_run(%Run{} = run, container, executing?, input, mode) do
    cancel? = run.cancel_requested_at != nil

    cond do
      executing? and cancel? ->
        [{:cancel, run.id}]

      executing? ->
        []

      container != nil ->
        [{:attach, run, cancel?}]

      cancel? ->
        [{:mark_cancelled, run.id}]

      run.status == :preparing ->
        if lost?(run, input.now, mode), do: [{:fail, run.id, @lost_while_preparing}], else: []

      true ->
        [{:fail, run.id, @container_disappeared}]
    end
  end

  defp lost?(_run, _now, :startup), do: true

  defp lost?(run, now, :periodic),
    do: DateTime.diff(now, run.updated_at, :second) >= @preparing_grace_seconds

  defp plan_container(container, input) do
    %{run_id: run_id} = container

    cond do
      MapSet.member?(input.executing, run_id) ->
        []

      MapSet.member?(input.final_run_ids, run_id) ->
        [{:remove, run_id, container.container_id}]

      not MapSet.member?(input.existing_run_ids, run_id) and container.instance == input.instance ->
        [{:remove_orphan, container}]

      true ->
        []
    end
  end

  ## Actions

  defp execute({:cancel, run_id} = action) do
    Execution.cancel(run_id)
    action
  end

  defp execute({:attach, run, cancel?} = action) do
    # The run may have finished between reading it and now.
    if still_active?(run.id) do
      opts = [
        handler: Recorder,
        last_log_timestamp: run.last_log_timestamp,
        next_sequence: run.last_log_sequence + 1,
        artifact_path: Storage.run_dir(run.id),
        max_artifact_bytes: Artifacts.max_bytes(),
        cancel: cancel?
      ]

      case Execution.attach(run.id, opts) do
        {:ok, _pid} ->
          Logger.info("run #{run.id}: reattached#{if cancel?, do: " to cancel it"}")

        # Started by someone else in the meantime.
        {:error, :already_running} ->
          :ok

        {:error, reason} ->
          Logger.warning("run #{run.id}: cannot reattach: #{inspect(reason)}")
      end
    end

    action
  end

  defp execute({:mark_cancelled, run_id} = action) do
    Logger.info("run #{run_id}: cancelled without a container")
    Runs.mark_cancelled(run_id)
    action
  end

  defp execute({:fail, run_id, message} = action) do
    Logger.warning("run #{run_id}: #{message}")
    Runs.fail(run_id, message)
    action
  end

  defp execute({:remove, run_id, container_id} = action) do
    case Execution.remove_container(container_id) do
      :ok ->
        Logger.info("run #{run_id}: removed the leftover container")

      {:error, error} ->
        Logger.warning("run #{run_id}: cannot remove the leftover container: #{error.message}")
    end

    action
  end

  defp execute({:remove_orphan, container} = action) do
    Logger.warning(
      "container #{String.slice(container.container_id, 0, 12)} (run #{container.run_id}) " <>
        "has no run in this database; stopping and removing it"
    )

    # Stopping waits for the grace period; the pass does not.
    Task.start(fn ->
      Execution.stop_and_remove_container(container.container_id, container.stop_grace_seconds)
    end)

    action
  end

  defp still_active?(run_id),
    do: Runs.get_run!(run_id).status in Run.active_statuses() and not Execution.executing?(run_id)
end
