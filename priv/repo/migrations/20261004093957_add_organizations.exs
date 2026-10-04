defmodule TestFleet.Repo.Migrations.AddOrganizations do
  use Ecto.Migration

  # Organizations are the tenants. An installation from before them gets one,
  # "Default", holding all existing data, with every user as a member in the role
  # they had. A new installation gets its organization from the first-run setup.
  @owned [:projects, :registries, :notification_channels, :api_tokens, :runs]

  def up do
    create table(:organizations) do
      add :name, :string, null: false
      add :slug, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])

    create table(:memberships) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      add :role, :string, null: false, default: "member"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:memberships, [:user_id, :organization_id])
    create index(:memberships, [:organization_id])
    create constraint(:memberships, :role_must_be_known, check: "role IN ('admin', 'member')")

    for table <- @owned do
      alter table(table) do
        add :organization_id, references(:organizations, on_delete: :restrict)
      end
    end

    flush()

    execute """
    INSERT INTO organizations (name, slug, inserted_at, updated_at)
    SELECT 'Default', 'default', now(), now()
    WHERE EXISTS (SELECT 1 FROM users) OR EXISTS (SELECT 1 FROM projects)
       OR EXISTS (SELECT 1 FROM registries) OR EXISTS (SELECT 1 FROM notification_channels)
    """

    for table <- @owned do
      execute "UPDATE #{table} SET organization_id = (SELECT id FROM organizations)"
    end

    execute """
    INSERT INTO memberships (user_id, organization_id, role, inserted_at, updated_at)
    SELECT u.id, o.id, u.role, now(), now() FROM users u CROSS JOIN organizations o
    """

    for table <- @owned do
      execute "ALTER TABLE #{table} ALTER COLUMN organization_id SET NOT NULL"
    end

    # Unique per organization from now on
    drop unique_index(:projects, [:slug])
    create unique_index(:projects, [:organization_id, :slug])
    drop unique_index(:registries, [:host])
    create unique_index(:registries, [:organization_id, :host])
    drop index(:notification_channels, [:name], name: :notification_channels_name_index)

    create unique_index(:notification_channels, [:organization_id, "lower(name)"],
             name: :notification_channels_organization_id_name_index
           )

    create index(:api_tokens, [:organization_id])
    create index(:runs, [:organization_id, :id])

    drop constraint(:users, :role_must_be_known)

    alter table(:users) do
      remove :role
    end
  end

  def down do
    alter table(:users) do
      add :role, :string, null: false, default: "member"
    end

    create constraint(:users, :role_must_be_known, check: "role IN ('admin', 'member')")

    # A user who is an admin anywhere becomes an admin.
    execute """
    UPDATE users SET role = 'admin'
    WHERE id IN (SELECT user_id FROM memberships WHERE role = 'admin')
    """

    drop index(:runs, [:organization_id, :id])
    drop index(:api_tokens, [:organization_id])

    drop index(:notification_channels, [:name],
           name: :notification_channels_organization_id_name_index
         )

    create unique_index(:notification_channels, ["lower(name)"],
             name: :notification_channels_name_index
           )

    drop unique_index(:registries, [:organization_id, :host])
    create unique_index(:registries, [:host])
    drop unique_index(:projects, [:organization_id, :slug])
    create unique_index(:projects, [:slug])

    for table <- @owned do
      alter table(table) do
        remove :organization_id
      end
    end

    drop table(:memberships)
    drop table(:organizations)
  end
end
