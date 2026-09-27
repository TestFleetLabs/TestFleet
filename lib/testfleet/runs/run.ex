defmodule TestFleet.Runs.Run do
  @moduledoc """
  One execution of a test definition against an environment (main spec section 7).

  `image` and `command` are copied from the test definition when the run is
  created; everything else is read when the run starts. Status changes go through
  `TestFleet.Runs`, as conditional updates, so a finished run is never reopened.
  """
  use Ecto.Schema

  @statuses [:queued, :preparing, :running, :passed, :failed, :cancelled, :timeout, :error]
  @active_statuses [:preparing, :running]
  @final_statuses [:passed, :failed, :cancelled, :timeout, :error]

  schema "runs" do
    field :trigger, Ecto.Enum, values: [:manual, :schedule, :api]
    field :scheduled_for, :utc_datetime_usec

    field :status, Ecto.Enum, values: @statuses, default: :queued

    field :image, :string
    field :command, {:array, :string}, default: []
    field :image_digest, :string

    field :container_id, :string
    field :last_log_timestamp, :integer

    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    field :exit_code, :integer
    field :oom_killed, :boolean, default: false
    field :error_message, :string

    belongs_to :test_definition, TestFleet.TestDefinitions.TestDefinition
    belongs_to :environment, TestFleet.Environments.Environment
    belongs_to :schedule, TestFleet.Schedules.Schedule

    timestamps(type: :utc_datetime_usec)
  end

  def statuses, do: @statuses

  @doc "Statuses that hold a slot under the concurrency limits."
  def active_statuses, do: @active_statuses

  def final_statuses, do: @final_statuses

  def final?(%__MODULE__{status: status}), do: status in @final_statuses
end
