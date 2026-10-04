defmodule TestFleet.Repo.Migrations.AddApiTokenToRuns do
  use Ecto.Migration

  # Which token started an API run
  def change do
    alter table(:runs) do
      add :api_token_id, references(:api_tokens, on_delete: :nilify_all)
    end

    create index(:runs, [:api_token_id])
  end
end
