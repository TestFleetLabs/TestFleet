defmodule TestFleet.Environments.Environment do
  @moduledoc """
  A target system of a project, such as production or staging, with the variables
  a suite needs to reach it.

  `max_concurrent_runs` limits how many runs may execute against this environment
  at the same time.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TestFleet.Environments.Variable
  alias TestFleet.Slug

  schema "environments" do
    field :name, :string
    field :slug, :string
    field :description, :string
    field :max_concurrent_runs, :integer, default: 1
    field :variable_count, :integer, virtual: true

    belongs_to :project, TestFleet.Projects.Project
    has_many :variables, Variable, preload_order: [asc: :key]

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(environment, attrs) do
    environment
    |> cast(attrs, [:name, :slug, :description, :max_concurrent_runs])
    |> validate_required([:name, :max_concurrent_runs])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 2000)
    |> validate_number(:max_concurrent_runs,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 100
    )
    |> Slug.put_and_validate()
    |> unique_constraint(:slug, name: :environments_project_id_slug_index)
  end
end
