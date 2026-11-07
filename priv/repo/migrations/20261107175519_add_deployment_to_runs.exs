defmodule TestFleet.Repo.Migrations.AddDeploymentToRuns do
  use Ecto.Migration

  # What a pipeline deployed before it started the run: version, commit, and a
  # link. Null when nobody said (manual and scheduled runs, older API runs).
  def change do
    alter table(:runs) do
      add :deployment, :map
    end
  end
end
