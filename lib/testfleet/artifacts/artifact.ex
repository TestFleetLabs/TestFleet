defmodule TestFleet.Artifacts.Artifact do
  @moduledoc """
  One file a run left in `/TestFleet/artifacts` (main spec section 11, Milestone 6
  section 3). `name` is its path relative to that directory; `storage_key` is
  resolved to a file by `TestFleet.Artifacts.Storage` only.

  Written with the run's final status by `TestFleet.Runs.finish/2`, never changed.
  """
  use Ecto.Schema

  schema "artifacts" do
    field :name, :string
    field :content_type, :string
    field :size_bytes, :integer
    field :storage_backend, :string
    field :storage_key, :string

    belongs_to :run, TestFleet.Runs.Run

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
