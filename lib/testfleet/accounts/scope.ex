defmodule TestFleet.Accounts.Scope do
  @moduledoc """
  The caller, assigned as `current_scope`: the logged-in user and, on
  organization pages, the organization and the user's membership in it.

  Roles belong to the membership: `admin?/1` and `role/1` read it.
  """

  alias TestFleet.Accounts.User
  alias TestFleet.Organizations
  alias TestFleet.Organizations.{Membership, Organization}

  defstruct user: nil, organization: nil, membership: nil

  @doc """
  Creates a scope for the given user. In `:single` mode it carries the
  organization and the user's membership in it.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    scope = %__MODULE__{user: user}

    if Organizations.multi?() do
      scope
    else
      case Organizations.single() do
        nil -> scope
        organization -> put_organization(scope, organization)
      end
    end
  end

  def for_user(nil), do: nil

  @doc "The scope within `organization`, with the user's membership there (nil if none)."
  def put_organization(%__MODULE__{user: user} = scope, %Organization{} = organization) do
    put_organization(scope, organization, Organizations.get_membership(user, organization))
  end

  def put_organization(%__MODULE__{} = scope, %Organization{} = organization, membership) do
    %{scope | organization: organization, membership: membership}
  end

  @doc "The user's role in the scope's organization, or nil."
  def role(%__MODULE__{membership: %Membership{role: role}}), do: role
  def role(_scope), do: nil

  @doc "Whether the scope's user is an admin of its organization."
  def admin?(scope), do: role(scope) == :admin
end
