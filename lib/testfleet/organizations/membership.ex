defmodule TestFleet.Organizations.Membership do
  @moduledoc """
  A user's membership in an organization, with their role there: `admin` or
  `member`. Roles belong to memberships, not to users.
  """
  use Ecto.Schema

  @roles [:admin, :member]

  schema "memberships" do
    field :role, Ecto.Enum, values: @roles, default: :member

    belongs_to :user, TestFleet.Accounts.User
    belongs_to :organization, TestFleet.Organizations.Organization

    timestamps(type: :utc_datetime)
  end

  @doc "The roles, least privileged last."
  def roles, do: @roles
end
