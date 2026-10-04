defmodule TestFleet.Repo.Migrations.CreateRegistries do
  use Ecto.Migration

  def change do
    create table(:registries) do
      add :name, :string, null: false
      # Matched against the host of image references
      add :host, :string, null: false
      add :username, :string, null: false
      # Encrypted with TestFleet.Vault
      add :password_encrypted, :binary, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:registries, [:host])
  end
end
