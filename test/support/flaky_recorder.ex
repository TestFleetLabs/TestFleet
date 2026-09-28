defmodule TestFleet.FlakyRecorder do
  @moduledoc """
  `TestFleet.Runs.Recorder`, except that the first output batch after `arm/0` raises
  instead of being stored, like a database write failing mid-run (Milestone 7,
  section 7). One-shot and global: for tests that are not async.
  """
  @behaviour TestFleet.Execution.Handler

  alias TestFleet.Runs.Recorder

  @key {__MODULE__, :armed}

  def arm, do: :persistent_term.put(@key, true)

  def disarm, do: :persistent_term.erase(@key)

  @impl true
  def handle_event(run_id, {:output, _lines} = event) do
    if :persistent_term.get(@key, false) do
      disarm()
      raise DBConnection.ConnectionError, "simulated database failure"
    end

    Recorder.handle_event(run_id, event)
  end

  def handle_event(run_id, event), do: Recorder.handle_event(run_id, event)
end
