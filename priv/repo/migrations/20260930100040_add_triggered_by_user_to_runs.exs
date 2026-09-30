defmodule TestFleet.Repo.Migrations.AddTriggeredByUserToRuns do
  use Ecto.Migration

  # Who started a manual run (Milestone 10, section 6). Scheduled runs have none.
  def change do
    alter table(:runs) do
      add :triggered_by_user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:runs, [:triggered_by_user_id])
  end
end
