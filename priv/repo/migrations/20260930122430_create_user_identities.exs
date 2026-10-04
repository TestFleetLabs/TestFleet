defmodule TestFleet.Repo.Migrations.CreateUserIdentities do
  use Ecto.Migration

  # OIDC identities: a user's account at the provider,
  # matched by the provider's subject, never by email.
  def change do
    create table(:user_identities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :issuer, :string, null: false
      add :subject, :string, null: false
      add :email, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:user_identities, [:issuer, :subject])
    create unique_index(:user_identities, [:user_id, :issuer])
  end
end
