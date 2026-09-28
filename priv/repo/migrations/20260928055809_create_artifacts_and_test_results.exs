defmodule TestFleet.Repo.Migrations.CreateArtifactsAndTestResults do
  use Ecto.Migration

  def change do
    # Milestone 6 section 3. Neither table has `updated_at`: rows never change.
    create table(:artifacts) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      # Relative to the artifacts directory, e.g. screenshots/login.png
      add :name, :text, null: false
      add :content_type, :text, null: false
      add :size_bytes, :bigint, null: false
      add :storage_backend, :text, null: false
      add :storage_key, :text, null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:artifacts, [:run_id, :name])

    create table(:test_results) do
      add :run_id, references(:runs, on_delete: :delete_all), null: false
      # Copied from the run: a test's identity across runs (main spec section 10)
      add :test_definition_id, references(:test_definitions, on_delete: :delete_all), null: false

      add :suite, :text, null: false
      add :classname, :text, null: false
      add :name, :text, null: false
      add :status, :text, null: false
      add :duration_ms, :integer
      add :failure_message, :text
      add :failure_details, :text
      # The JUnit file it came from, e.g. junit/shard-2.xml
      add :file, :text, null: false

      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:test_results, [:test_definition_id, :suite, :classname, :name])
    create index(:test_results, [:run_id, :status])

    alter table(:runs) do
      # From JUnit; nil when the run had none. tests_failed includes errors.
      add :tests_passed, :integer
      add :tests_failed, :integer
      add :tests_skipped, :integer
      add :warnings, {:array, :text}, null: false, default: []

      # Retention (slice D)
      add :pinned, :boolean, null: false, default: false
      add :artifacts_expired_at, :utc_datetime_usec
      add :logs_expired_at, :utc_datetime_usec
    end
  end
end
