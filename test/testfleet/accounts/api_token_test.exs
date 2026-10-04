defmodule TestFleet.Accounts.APITokenTest do
  # API tokens
  use TestFleet.DataCase, async: true

  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{APIToken, Scope}

  setup do
    user = user_fixture()
    %{user: user, scope: Scope.for_user(user)}
  end

  describe "create_api_token/2" do
    test "returns the token once and stores only its hash and hint", %{scope: scope} do
      assert {:ok, {"tf_" <> rest = token, api_token}} =
               Accounts.create_api_token(scope, %{name: " GitLab deploy ", expires_in: "30"})

      assert byte_size(rest) == 43
      assert api_token.name == "GitLab deploy"
      assert api_token.hint == String.slice(token, -4, 4)

      stored = Repo.get!(APIToken, api_token.id)
      assert stored.token_hash == :crypto.hash(:sha256, token)
      assert DateTime.diff(stored.expires_at, DateTime.utc_now(), :day) in 29..30
    end

    test "can create tokens that never expire", %{scope: scope} do
      assert {:ok, {_token, %{expires_at: nil}}} =
               Accounts.create_api_token(scope, %{name: "forever", expires_in: "never"})
    end

    test "validates the name and the expiry", %{scope: scope} do
      assert {:error, changeset} = Accounts.create_api_token(scope, %{name: "", expires_in: "7"})
      assert %{name: ["can't be blank"], expires_in: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "list_api_tokens/1 and delete_api_token/2" do
    test "are limited to the scope's user", %{user: user, scope: scope} do
      {_token, mine} = api_token_fixture(user)
      other_user = user_fixture()
      {_token, theirs} = api_token_fixture(other_user)

      assert [%{id: id}] = Accounts.list_api_tokens(scope)
      assert id == mine.id

      assert {:error, :not_found} = Accounts.delete_api_token(scope, theirs.id)
      assert [_] = Accounts.list_api_tokens(Scope.for_user(other_user))

      assert :ok = Accounts.delete_api_token(scope, mine.id)
      assert [] = Accounts.list_api_tokens(scope)
    end
  end

  describe "get_user_by_api_token/2" do
    test "returns the user and the token", %{user: user} do
      {token, api_token} = api_token_fixture(user)

      assert {found, %APIToken{id: id}} = Accounts.get_user_by_api_token(token)
      assert found.id == user.id
      assert id == api_token.id
    end

    test "refuses unknown, malformed, and revoked tokens", %{user: user, scope: scope} do
      {token, api_token} = api_token_fixture(user)

      refute Accounts.get_user_by_api_token("tf_" <> String.duplicate("a", 43))
      refute Accounts.get_user_by_api_token("not a token")
      refute Accounts.get_user_by_api_token(String.slice(token, 0..-2//1))

      :ok = Accounts.delete_api_token(scope, api_token.id)
      refute Accounts.get_user_by_api_token(token)
    end

    test "refuses expired tokens", %{user: user} do
      {token, api_token} = api_token_fixture(user, %{expires_in: "30"})
      later = DateTime.add(api_token.expires_at, 1, :second)

      assert Accounts.get_user_by_api_token(token, DateTime.add(later, -2, :second))
      refute Accounts.get_user_by_api_token(token, later)
    end

    test "deactivating the user deletes the tokens", %{user: user} do
      admin_fixture()
      {token, _api_token} = api_token_fixture(user)

      {:ok, _} = Accounts.deactivate_user(user)

      refute Accounts.get_user_by_api_token(token)
      assert Repo.aggregate(APIToken, :count) == 0
    end

    test "records the use at most every 5 minutes", %{user: user} do
      {token, api_token} = api_token_fixture(user)
      now = DateTime.utc_now(:second)

      {_user, %{last_used_at: first}} = Accounts.get_user_by_api_token(token, now)
      assert first == now

      Accounts.get_user_by_api_token(token, DateTime.add(now, 4, :minute))
      assert Repo.get!(APIToken, api_token.id).last_used_at == now

      later = DateTime.add(now, 5, :minute)
      Accounts.get_user_by_api_token(token, later)
      assert Repo.get!(APIToken, api_token.id).last_used_at == later
    end
  end
end
