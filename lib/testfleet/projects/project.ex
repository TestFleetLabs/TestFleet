defmodule TestFleet.Projects.Project do
  @moduledoc """
  One application under test. Groups its test definitions, environments, and
  schedules.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TestFleet.Slug

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :description, :string

    belongs_to :organization, TestFleet.Organizations.Organization

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :slug, :description])
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 2000)
    |> Slug.put_and_validate()
    |> unique_constraint(:slug, name: :projects_organization_id_slug_index)
  end
end
