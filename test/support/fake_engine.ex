defmodule TestFleet.FakeEngine do
  @moduledoc """
  Stands in for `TestFleet.Execution` in dispatcher tests: records each start as
  `{:engine_started, request, opts}` to `opts[:test_pid]` without running anything.

  With `result: {:error, reason}` in the engine options, every start fails.
  """

  def start(request, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:engine_started, request, opts})
    Keyword.get(opts, :result, {:ok, self()})
  end
end
