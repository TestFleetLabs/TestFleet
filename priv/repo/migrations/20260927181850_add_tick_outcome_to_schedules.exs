defmodule TestFleet.Repo.Migrations.AddTickOutcomeToSchedules do
  use Ecto.Migration

  def change do
    # What the schedule tick last did (Milestone 5, section 3), so a skip is visible.
    alter table(:schedules) do
      add :last_tick_at, :utc_datetime
      add :last_tick_outcome, :text
      add :last_run_id, references(:runs, on_delete: :nilify_all)
    end
  end
end
