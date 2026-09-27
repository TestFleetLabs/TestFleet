defmodule TestFleet.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules) do
      add :test_definition_id, references(:test_definitions, on_delete: :delete_all), null: false

      add :environment_id, references(:environments, on_delete: :delete_all), null: false

      add :cron_expression, :string, null: false
      add :timezone, :string, null: false
      # UTC; computed from the cron expression in the schedule's timezone (main spec section 28)
      add :next_run_at, :utc_datetime, null: false
      add :overlap_policy, :string, null: false, default: "skip"
      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create index(:schedules, [:test_definition_id])
    create index(:schedules, [:environment_id])
    # The schedule tick asks: which enabled schedules are due?
    create index(:schedules, [:next_run_at], where: "enabled")
  end
end
