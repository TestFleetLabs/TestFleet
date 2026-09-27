defmodule TestFleet.Execution.Recovery do
  @moduledoc """
  Startup recovery (Milestone 3, section 9): picks up the runs that were active when
  TestFleet stopped. The dispatcher runs it once, before its first pass.

  | Run status              | Container | Action                                  |
  |-------------------------|-----------|-----------------------------------------|
  | `preparing`             | missing   | finalize as `error`                     |
  | `preparing` / `running` | present   | attach, with `TestFleet.Runs.Recorder`  |
  | `running`               | missing   | finalize as `error`                     |
  | final                   | present   | remove the container                    |

  Runs that still have a `RunExecution` process (the dispatcher restarted, not
  TestFleet) are left alone. Containers without a run row are not touched: they may
  belong to another database on the same Docker host. Removing orphans is the
  reconciler's job (Milestone 7).

  Without an answer from Docker nothing is changed.
  """

  require Logger

  alias TestFleet.Execution
  alias TestFleet.Runs
  alias TestFleet.Runs.Recorder

  @restarted_while_preparing "TestFleet restarted while preparing the run"
  @container_disappeared "container disappeared"

  @doc "Recovers the runs. Returns the actions taken, or `:skipped` without Docker."
  def run do
    case Execution.list_containers() do
      {:ok, containers} ->
        active_runs = Enum.reject(Runs.list_active(), &Execution.executing?(&1.id))
        final_run_ids = Runs.final_run_ids(Enum.map(containers, & &1.run_id))

        active_runs
        |> plan(final_run_ids, containers)
        |> Enum.map(&execute/1)

      {:error, error} ->
        Logger.warning("startup recovery skipped, Docker is not reachable: #{error.message}")
        :skipped
    end
  end

  @doc """
  Decides what to do, without side effects. `active_runs` are runs without a
  process, `final_run_ids` the finished runs among the containers' run ids.
  """
  def plan(active_runs, final_run_ids, containers) do
    run_ids_with_container = MapSet.new(containers, & &1.run_id)

    runs =
      for run <- active_runs do
        cond do
          run.id in run_ids_with_container -> {:attach, run}
          run.status == :preparing -> {:fail, run.id, @restarted_while_preparing}
          true -> {:fail, run.id, @container_disappeared}
        end
      end

    final_run_ids = MapSet.new(final_run_ids)

    leftovers =
      for container <- containers,
          container.run_id in final_run_ids,
          do: {:remove, container.run_id, container.container_id}

    runs ++ leftovers
  end

  defp execute({:attach, run} = action) do
    case Execution.attach(run.id, handler: Recorder, last_log_timestamp: run.last_log_timestamp) do
      {:ok, _pid} ->
        Logger.info("run #{run.id}: reattached after restart")

      # Started by someone else in the meantime.
      {:error, :already_running} ->
        :ok

      {:error, reason} ->
        Logger.warning("run #{run.id}: cannot reattach: #{inspect(reason)}")
    end

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
end
