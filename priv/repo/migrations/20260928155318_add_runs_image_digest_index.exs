defmodule TestFleet.Repo.Migrations.AddRunsImageDigestIndex do
  use Ecto.Migration

  # Image cleanup candidates
  def change do
    create index(:runs, [:image, :image_digest], where: "image_digest IS NOT NULL")
  end
end
