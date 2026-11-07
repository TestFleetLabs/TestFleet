defmodule TestFleet.Repo.Migrations.AddRunsListIndexes do
  use Ecto.Migration

  # The runs list's filters: an environment's runs by page, and runs by the
  # version or the start of the commit they deployed.
  def change do
    create index(:runs, [:environment_id, :id])

    create index(:runs, ["(deployment->>'version')"],
             name: :runs_deployment_version_index,
             where: "deployment IS NOT NULL"
           )

    create index(:runs, ["(deployment->>'commit') text_pattern_ops"],
             name: :runs_deployment_commit_index,
             where: "deployment IS NOT NULL"
           )
  end
end
