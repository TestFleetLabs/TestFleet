defmodule TestFleet.Results.TestResult do
  @moduledoc """
  One test case of a run's JUnit report (main spec section 10, Milestone 6
  section 3). `test_definition_id`, `suite`, `classname`, and `name` identify a
  test across runs.

  Written with the run's final status by `TestFleet.Runs.finish/2`, never changed.
  """
  use Ecto.Schema

  @statuses [:passed, :failed, :error, :skipped]

  schema "test_results" do
    field :suite, :string
    field :classname, :string
    field :name, :string
    field :status, Ecto.Enum, values: @statuses
    field :duration_ms, :integer
    field :failure_message, :string
    field :failure_details, :string
    field :file, :string

    belongs_to :run, TestFleet.Runs.Run
    belongs_to :test_definition, TestFleet.TestDefinitions.TestDefinition

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def statuses, do: @statuses
end
