defmodule TestFleet.Repo.Migrations.CreateTestDefinitions do
  use Ecto.Migration

  def change do
    create table(:test_definitions) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :description, :text

      # Image references with a digest are longer than 255 characters at times
      add :image, :text, null: false
      # argv array; empty means the image's own ENTRYPOINT/CMD (main spec section 6)
      add :command, {:array, :text}, null: false, default: []

      add :timeout_seconds, :integer, null: false, default: 1800
      add :cpu_limit, :float
      add :memory_limit, :bigint
      add :shm_size_bytes, :bigint, null: false, default: 2_147_483_648

      add :enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create unique_index(:test_definitions, [:project_id, :slug])
  end
end
