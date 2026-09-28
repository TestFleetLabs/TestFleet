defmodule TestFleet.Repo.Migrations.AddRunsImageDigestIndex do
  use Ecto.Migration

  # Image cleanup candidates (Milestone 7, section 8)
  def change do
    create index(:runs, [:image, :image_digest], where: "image_digest IS NOT NULL")
  end
end
