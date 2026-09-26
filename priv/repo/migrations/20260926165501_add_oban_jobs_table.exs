defmodule TestFleet.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up, do: Oban.Migration.up(version: 14)

  # Drops all Oban tables, whatever version they reached.
  def down, do: Oban.Migration.down(version: 1)
end
