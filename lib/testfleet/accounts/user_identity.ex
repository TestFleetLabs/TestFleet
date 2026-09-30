defmodule TestFleet.Accounts.UserIdentity do
  @moduledoc """
  A user's account at the OIDC provider (Milestone 10, section 7), matched by the
  provider's `issuer` and `subject` (`sub`). The email is kept as last seen, for
  display only.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_identities" do
    field :issuer, :string
    field :subject, :string
    field :email, :string
    belongs_to :user, TestFleet.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(identity, attrs) do
    identity
    |> cast(attrs, [:issuer, :subject, :email])
    |> validate_required([:issuer, :subject])
    |> unique_constraint([:issuer, :subject], message: "is linked to another user")
    |> unique_constraint([:user_id, :issuer], message: "is already linked")
  end
end
