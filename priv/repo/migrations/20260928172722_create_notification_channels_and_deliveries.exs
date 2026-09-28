defmodule TestFleet.Repo.Migrations.CreateNotificationChannelsAndDeliveries do
  use Ecto.Migration

  # Milestone 8, sections 4 and 8
  def change do
    create table(:notification_channels) do
      add :name, :string, null: false
      add :kind, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :email_recipients, {:array, :string}, null: false, default: []
      # Slack, Teams, and webhook URLs carry their token: encrypted like passwords.
      add :url_encrypted, :binary
      add :url_hint, :string
      add :signing_secret_encrypted, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:notification_channels, ["lower(name)"],
             name: :notification_channels_name_index
           )

    create table(:notification_deliveries) do
      add :channel_id, references(:notification_channels, on_delete: :delete_all), null: false
      add :run_id, references(:runs, on_delete: :delete_all)
      add :event, :string, null: false
      add :dedupe_key, :string, null: false
      add :data, :map, null: false, default: %{}
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :last_error, :string, size: 500
      add :sent_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:notification_deliveries, [:channel_id, :dedupe_key])
    create index(:notification_deliveries, [:run_id])
    create index(:notification_deliveries, [:inserted_at])
  end
end
