defmodule TestFleet.Repo.Migrations.CreateNotificationSubscriptions do
  use Ecto.Migration

  # Which events of which projects and environments a channel receives
  def change do
    create table(:notification_subscriptions) do
      add :channel_id, references(:notification_channels, on_delete: :delete_all), null: false
      # Both empty: all projects. An environment always comes with its project.
      add :project_id, references(:projects, on_delete: :delete_all)
      add :environment_id, references(:environments, on_delete: :delete_all)
      add :events, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create index(:notification_subscriptions, [:channel_id])
    create index(:notification_subscriptions, [:project_id])
    create index(:notification_subscriptions, [:environment_id])

    create constraint(:notification_subscriptions, :environment_needs_project,
             check: "environment_id IS NULL OR project_id IS NOT NULL"
           )
  end
end
