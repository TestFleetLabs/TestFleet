defmodule TestFleet.Repo.Migrations.AddRetentionToTestDefinitions do
  use Ecto.Migration

  def change do
    # Empty means the instance default (ARTIFACT_RETENTION_DAYS, LOG_RETENTION_DAYS).
    alter table(:test_definitions) do
      add :artifact_retention_days, :integer
      add :log_retention_days, :integer
    end
  end
end
