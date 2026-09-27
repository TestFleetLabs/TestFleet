defmodule TestFleet.Repo.Migrations.CreateRunLogs do
  use Ecto.Migration

  def change do
    # One row per line (main spec section 9, Milestone 4 section 3). No timestamps:
    # rows are never updated, and `timestamp` is Docker's own time of the line.
    create table(:run_logs) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      add :sequence, :integer, null: false
      add :stream, :text, null: false
      add :content, :text, null: false
      add :timestamp, :bigint
    end

    create unique_index(:run_logs, [:run_id, :sequence])

    alter table(:runs) do
      add :last_log_sequence, :integer, null: false, default: 0
      add :log_bytes, :bigint, null: false, default: 0
      add :log_truncated, :boolean, null: false, default: false
    end
  end
end
