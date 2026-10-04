defmodule TestFleet.Organizations.Organization do
  @moduledoc """
  A tenant. Everything users configure and run belongs to exactly one
  organization; its slug is the first segment of its pages' URLs.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TestFleet.Slug

  # Top-level path segments TestFleet uses or may use; an organization's slug
  # cannot take them.
  @reserved ~w(
    about account accounts admin api app assets auth billing dev docs fonts health
    help images js css live login logout new organizations org orgs phoenix runs
    settings setup signup static status support users www
  )

  # ~p"/#{organization}/projects" uses the slug.
  @derive {Phoenix.Param, key: :slug}
  schema "organizations" do
    field :name, :string
    field :slug, :string

    has_many :memberships, TestFleet.Organizations.Membership

    timestamps(type: :utc_datetime)
  end

  @doc "The slugs no organization can have."
  def reserved_slugs, do: @reserved

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: 100)
    |> Slug.put_and_validate()
    |> validate_exclusion(:slug, @reserved, message: "is reserved")
    |> unique_constraint(:slug)
  end
end
