defmodule TestFleet.Execution.Result do
  @moduledoc """
  The outcome of one run.

  `logs` is only filled by `TestFleet.Execution.run/2`; `RunExecution` streams output
  as events and does not keep it.
  """

  defstruct [
    :run_id,
    :status,
    :error_message,
    :exit_code,
    :image,
    :image_digest,
    :container_id,
    :started_at,
    :finished_at,
    oom_killed: false,
    artifacts: [],
    logs: []
  ]

  @type status :: :passed | :failed | :cancelled | :timeout | :error

  @type t :: %__MODULE__{
          run_id: pos_integer(),
          status: status(),
          error_message: String.t() | nil,
          exit_code: integer() | nil,
          image: String.t() | nil,
          image_digest: String.t() | nil,
          container_id: String.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t(),
          oom_killed: boolean(),
          artifacts: [%{path: String.t(), size_bytes: non_neg_integer()}],
          logs: [TestFleet.Execution.LineBuffer.line()]
        }
end
