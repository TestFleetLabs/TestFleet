defmodule TestFleet.Execution.Handler do
  @moduledoc """
  Receives the events of a run, inside its `RunExecution` process (see
  `TestFleet.Execution.RunExecution` for the events).

  The handler is how the rest of TestFleet learns about a run without the execution
  subsystem knowing about the database: `TestFleet.Runs.Recorder` persists the
  events. A handler that raises crashes the run's process; its container keeps
  running and is recovered later.
  """

  @callback handle_event(run_id :: pos_integer(), event :: term()) :: any()
end
