defmodule TestFleet.Runs.LogLine do
  @moduledoc """
  One line of a run's output, already masked. `sequence`
  orders the lines of a run; `timestamp` is Docker's time in nanoseconds.

  Lines are written in batches with `TestFleet.Runs.append_log/2`, never changed.
  """
  use Ecto.Schema

  schema "run_logs" do
    field :sequence, :integer
    field :stream, Ecto.Enum, values: [:stdout, :stderr]
    field :content, :string
    field :timestamp, :integer

    belongs_to :run, TestFleet.Runs.Run
  end
end
