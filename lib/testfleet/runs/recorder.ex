defmodule TestFleet.Runs.Recorder do
  @moduledoc """
  Persists the events of a run's execution.

  Runs inside the run's `RunExecution` process, so runs are recorded in parallel.
  Every write is a guarded transition: an event that arrives late, or twice, never
  changes a finished run.
  """
  @behaviour TestFleet.Execution.Handler

  alias TestFleet.Runs

  @impl true
  def handle_event(run_id, {:image_digest, digest}), do: Runs.record(run_id, image_digest: digest)

  def handle_event(run_id, {:container_created, container_id}),
    do: Runs.record(run_id, container_id: container_id)

  def handle_event(run_id, {:running, started_at}), do: Runs.mark_running(run_id, started_at)

  def handle_event(run_id, {:output, lines}), do: Runs.append_log(run_id, lines)

  def handle_event(run_id, {:finished, result}), do: Runs.finish(run_id, result)

  # `{:status, :preparing}` was set by the dispatcher.
  def handle_event(_run_id, _event), do: :ok
end
