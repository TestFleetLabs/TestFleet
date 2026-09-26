defmodule TestFleet.Repo.Migrations.CreateEnvironments do
  use Ecto.Migration

  def change do
    create table(:environments) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text
      add :max_concurrent_runs, :integer, null: false, default: 1

      timestamps(type: :utc_datetime)
    end

    create unique_index(:environments, [:project_id, :slug])

    create table(:environment_variables) do
      add :environment_id, references(:environments, on_delete: :delete_all), null: false
      add :key, :string, null: false
      # Encrypted with TestFleet.Vault, secret or not (main spec section 6)
      add :value_encrypted, :binary, null: false
      add :secret, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:environment_variables, [:environment_id, :key])
  end
end
