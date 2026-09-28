defmodule TestFleet.Execution.Reconnect do
  @moduledoc """
  What `RunExecution` does after it lost its streams to a container (Milestone 7,
  section 7), given Docker's answer to `inspect`:

    * `:follow` - the container runs: follow it again
    * `:exited` - it exited meanwhile: read the rest of its output and finalize
    * `:missing` - it is gone: finalize `error`
    * `:retry` - Docker did not answer: ask again later
    * `:give_up` - Docker has not answered for `window` milliseconds: stop without
      finalizing, and leave the run to the reconciler
  """

  @type action :: :follow | :exited | :missing | :retry | :give_up

  @spec decide({:ok, map()} | {:error, map()}, non_neg_integer(), non_neg_integer()) :: action()
  def decide({:ok, %{"State" => %{"Running" => true}}}, _elapsed, _window), do: :follow
  def decide({:ok, %{"State" => _}}, _elapsed, _window), do: :exited
  def decide({:error, %{status: 404}}, _elapsed, _window), do: :missing
  def decide({:error, _}, elapsed, window) when elapsed >= window, do: :give_up
  def decide({:error, _}, _elapsed, _window), do: :retry
end
