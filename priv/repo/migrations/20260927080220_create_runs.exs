defmodule TestFleet.Repo.Migrations.CreateRuns do
  use Ecto.Migration

  def change do
    create table(:runs) do
      # Run history must not disappear with its configuration.
      add :test_definition_id, references(:test_definitions, on_delete: :restrict), null: false
      add :environment_id, references(:environments, on_delete: :restrict), null: false

      add :trigger, :string, null: false
      add :schedule_id, references(:schedules, on_delete: :nilify_all)
      add :scheduled_for, :utc_datetime_usec

      add :status, :string, null: false, default: "queued"

      # Copied from the test definition when the run is created
      add :image, :string, size: 1000, null: false
      add :command, {:array, :text}, null: false, default: []
      add :image_digest, :string

      add :container_id, :string
      # Docker's timestamp of the last stored log line, in nanoseconds (main spec section 32)
      add :last_log_timestamp, :bigint

      add :queued_at, :utc_datetime_usec, null: false
      # The container's State.StartedAt; the deadline is derived from it
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec

      add :exit_code, :integer
      add :oom_killed, :boolean, null: false, default: false
      add :error_message, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runs, [:schedule_id, :scheduled_for])
    create index(:runs, [:test_definition_id, :id])
    create index(:runs, [:environment_id, :status])
    # The dispatcher asks for queued runs and counts active ones.
    create index(:runs, [:status], where: "status IN ('queued', 'preparing', 'running')")
  end
end
