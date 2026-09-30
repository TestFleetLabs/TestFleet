defmodule TestFleet.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `TestFleet.Accounts` context.
  """

  import Ecto.Query

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{Scope, User}
  alias TestFleet.Repo

  def unique_user_email, do: "user#{System.unique_integer()}@example.com"
  def valid_user_password, do: "hello world!"

  def valid_user_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      email: unique_user_email(),
      password: valid_user_password(),
      role: :member
    })
  end

  @doc "An active member with a password (`valid_user_password/0`)."
  def user_fixture(attrs \\ %{}) do
    attrs = valid_user_attributes(attrs)

    %User{}
    |> User.invite_changeset(attrs)
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> Repo.insert!()
  end

  @doc "An active admin with a password."
  def admin_fixture(attrs \\ %{}), do: attrs |> Enum.into(%{role: :admin}) |> user_fixture()

  @doc "A user who has not accepted the invitation yet. Returns `{user, token}`."
  def invited_user_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{email: unique_user_email(), role: :member})
    {:ok, %{user: user, url: token}} = Accounts.invite_user(attrs, & &1)
    {user, token}
  end

  @doc "A deactivated member."
  def deactivated_user_fixture(attrs \\ %{}) do
    {:ok, {user, _tokens}} = attrs |> user_fixture() |> Accounts.deactivate_user()
    user
  end

  def user_scope_fixture do
    user = user_fixture()
    user_scope_fixture(user)
  end

  def user_scope_fixture(user) do
    Scope.for_user(user)
  end

  def set_password(user) do
    {:ok, {user, _expired_tokens}} =
      Accounts.update_user_password(user, %{password: valid_user_password()})

    user
  end

  def extract_user_token(fun) do
    {:ok, captured_email} = fun.(&"[TOKEN]#{&1}[TOKEN]")
    [_, token | _] = String.split(captured_email.text_body, "[TOKEN]")
    token
  end

  def override_token_authenticated_at(token, authenticated_at) when is_binary(token) do
    Repo.update_all(
      from(t in Accounts.UserToken,
        where: t.token == ^token
      ),
      set: [authenticated_at: authenticated_at]
    )
  end

  def generate_user_magic_link_token(user) do
    {encoded_token, user_token} = Accounts.UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    {encoded_token, user_token.token}
  end

  def offset_user_token(token, amount_to_add, unit) do
    dt = DateTime.add(DateTime.utc_now(:second), amount_to_add, unit)

    Repo.update_all(
      from(ut in Accounts.UserToken, where: ut.token == ^token),
      set: [inserted_at: dt, authenticated_at: dt]
    )
  end
end
