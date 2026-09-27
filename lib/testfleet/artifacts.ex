defmodule TestFleet.Artifacts do
  @moduledoc """
  Files a suite leaves in `/TestFleet/artifacts` (main spec sections 11, 12, and 46).

  `RunExecution` collects them into `TestFleet.Artifacts.Storage`; this context
  holds the configuration and, from slice B, the `artifacts` rows.
  """

  @default_max_bytes 500 * 1024 * 1024

  @doc "The most a run may keep, measured on the archive (`ARTIFACT_LIMIT_MB`)."
  def max_bytes do
    Application.get_env(:testfleet, __MODULE__, [])[:max_bytes] || @default_max_bytes
  end
end
