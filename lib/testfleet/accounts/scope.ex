defmodule TestFleet.Accounts.Scope do
  @moduledoc """
  The caller: the logged-in user, assigned as `current_scope`.

  Roles are enforced at the edge (router, `on_mount`, controllers) with
  `admin?/1`. Contexts take a scope only for data that
  belongs to a user: so far, API tokens.
  """

  alias TestFleet.Accounts.User

  defstruct user: nil

  @doc """
  Creates a scope for the given user.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc "Whether the scope belongs to an admin."
  def admin?(%__MODULE__{user: %User{} = user}), do: User.admin?(user)
  def admin?(_scope), do: false
end
