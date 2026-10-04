defmodule TestFleet.Organizations do
  @moduledoc """
  Organizations, the tenants, and memberships: which users belong to an
  organization, and in which role.

  `config :testfleet, :organizations` is `:single` (self-hosted: exactly one
  organization, see `single/0`) or `:multi` (the hosted edition).
  """

  import Ecto.Query, warn: false

  alias TestFleet.Accounts.User
  alias TestFleet.Organizations.{Membership, Organization}
  alias TestFleet.Repo

  @doc "`:single` or `:multi`."
  def mode, do: Application.get_env(:testfleet, :organizations, :single)

  @doc "Whether users can belong to several organizations (the hosted edition)."
  def multi?, do: mode() == :multi

  @doc """
  The organization of a `:single` installation, or nil before the first-run
  setup created it. Not available in `:multi` mode.
  """
  def single do
    if multi?(), do: raise(ArgumentError, "there is no single organization in :multi mode")
    Repo.one(from o in Organization, order_by: o.id, limit: 1)
  end

  @doc "Like `single/0`, but raises when there is no organization yet."
  def single! do
    single() || raise Ecto.NoResultsError, queryable: Organization
  end

  def get_organization!(id), do: Repo.get!(Organization, id)

  @doc "The organization with this slug, or nil."
  def get_organization_by_slug(slug) when is_binary(slug),
    do: Repo.get_by(Organization, slug: slug)

  @doc "Creates an organization. Internal: the first-run setup and the hosted edition create them."
  def create_organization(attrs) do
    %Organization{}
    |> Organization.changeset(attrs)
    |> Repo.insert()
  end

  def update_organization(%Organization{} = organization, attrs) do
    organization
    |> Organization.changeset(attrs)
    |> Repo.update()
  end

  def change_organization(%Organization{} = organization, attrs \\ %{}),
    do: Organization.changeset(organization, attrs)

  defdelegate reserved_slugs, to: Organization

  ## Memberships

  @doc "The user's membership in the organization, or nil."
  def get_membership(%User{id: user_id}, %Organization{id: organization_id}),
    do: Repo.get_by(Membership, user_id: user_id, organization_id: organization_id)

  @doc "The user's memberships, with their organizations, by organization name."
  def list_memberships(%User{id: user_id}) do
    Repo.all(
      from m in Membership,
        join: o in assoc(m, :organization),
        where: m.user_id == ^user_id,
        order_by: fragment("lower(?)", o.name),
        preload: [organization: o]
    )
  end

  @doc """
  Makes the user a member of the organization in `role`, or changes the role of an
  existing membership.
  """
  def put_membership(%User{id: user_id}, %Organization{id: organization_id}, role)
      when role in [:admin, :member] do
    now = DateTime.utc_now(:second)

    Repo.insert(
      %Membership{
        user_id: user_id,
        organization_id: organization_id,
        role: role,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [set: [role: role, updated_at: now]],
      conflict_target: [:user_id, :organization_id],
      returning: true
    )
  end
end
