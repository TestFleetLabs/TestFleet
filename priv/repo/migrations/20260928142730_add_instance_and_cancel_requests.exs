defmodule TestFleet.Repo.Migrations.AddInstanceAndCancelRequests do
  use Ecto.Migration

  def change do
    # One row: this database's identity on the containers it starts (Milestone 7,
    # section 3). Generated here, so every database gets its own without configuration.
    create table(:instance, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :inserted_at, :utc_datetime_usec, null: false
    end

    execute(
      "INSERT INTO instance (id, inserted_at) VALUES (gen_random_uuid(), now())",
      "DELETE FROM instance"
    )

    # A cancel of an active run, kept until the run is final (Milestone 7, section 5)
    alter table(:runs) do
      add :cancel_requested_at, :utc_datetime_usec
    end
  end
end
