defmodule TestFleet.Accounts.OIDCTest do
  # OIDC identities and their four modes (Milestone 10, section 7).
  # Not async: some tests change the OIDC configuration.
  use TestFleet.DataCase, async: false

  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{OIDC, User, UserIdentity, UserToken}

  defp identity(attrs \\ %{}) do
    Enum.into(attrs, %{
      issuer: OIDC.issuer(),
      subject: "sub-#{System.unique_integer([:positive])}",
      email: unique_user_email(),
      email_verified: false
    })
  end

  defp put_oidc_config(changes) do
    previous = Application.get_env(:testfleet, OIDC)
    Application.put_env(:testfleet, OIDC, Keyword.merge(previous, changes))
    on_exit(fn -> Application.put_env(:testfleet, OIDC, previous) end)
  end

  describe "identity/1" do
    test "takes the subject and the email, lowercased" do
      assert {:ok, %{subject: "abc", email: "ann@example.com", email_verified: true}} =
               OIDC.identity(%{
                 "sub" => "abc",
                 "email" => "Ann@Example.com",
                 "email_verified" => true
               })
    end

    test "treats a missing email_verified as unverified (Entra ID, AD FS)" do
      assert {:ok, %{email_verified: false}} =
               OIDC.identity(%{"sub" => "abc", "email" => "ann@example.com"})
    end

    test "refuses claims without a subject or email" do
      assert {:error, :no_subject} = OIDC.identity(%{"email" => "ann@example.com"})
      assert {:error, :no_email} = OIDC.identity(%{"sub" => "abc"})
    end

    test "reads the email from the configured claim" do
      put_oidc_config(email_claim: "preferred_username")

      assert {:ok, %{email: "ann@corp.example"}} =
               OIDC.identity(%{"sub" => "abc", "preferred_username" => "ann@corp.example"})
    end
  end

  describe "oidc_login/1" do
    test "1. a known identity logs its user in, and its email is updated" do
      user = user_fixture()
      identity = identity()
      {:ok, _} = Accounts.link_identity(user, identity)

      assert {:ok, %User{id: id}} = Accounts.oidc_login(%{identity | email: "new@example.com"})
      assert id == user.id
      assert Repo.get_by!(UserIdentity, user_id: user.id).email == "new@example.com"
    end

    test "1. a known identity of a deactivated user is refused" do
      admin_fixture()
      user = user_fixture()
      identity = identity()
      {:ok, _} = Accounts.link_identity(user, identity)
      {:ok, _} = Accounts.deactivate_user(user)

      assert {:error, :deactivated} = Accounts.oidc_login(identity)
    end

    test "2. a verified email links the existing user" do
      user = user_fixture()

      assert {:ok, %User{id: id}} =
               Accounts.oidc_login(identity(email: user.email, email_verified: true))

      assert id == user.id
      assert Accounts.get_identity(user)
    end

    test "2. a verified email accepts a pending invitation" do
      {user, token} = invited_user_fixture()

      assert {:ok, user} = Accounts.oidc_login(identity(email: user.email, email_verified: true))
      assert User.status(user) == :active
      refute Accounts.get_user_by_invitation_token(token)
    end

    test "3. an unknown user gets a member account" do
      identity = identity()

      assert {:ok, %User{role: :member} = user} = Accounts.oidc_login(identity)
      assert User.status(user) == :active
      assert user.email == identity.email
      assert is_nil(user.hashed_password)
    end

    test "3. without provisioning, unknown users are refused" do
      put_oidc_config(provisioning: false)
      assert {:error, :not_invited} = Accounts.oidc_login(identity())
    end

    test "3. only allowed domains get an account" do
      put_oidc_config(allowed_domains: ["corp.example"])

      assert {:error, :domain_not_allowed} =
               Accounts.oidc_login(identity(email: "a@other.example"))

      assert {:ok, _} = Accounts.oidc_login(identity(email: "a@CORP.example"))
    end

    test "4. an unverified email that matches a user is refused" do
      user = user_fixture()

      assert {:error, :email_not_verified} = Accounts.oidc_login(identity(email: user.email))
      refute Accounts.get_identity(user)
    end
  end

  describe "oidc_setup/1" do
    test "creates the first admin with the identity" do
      assert {:ok, %User{role: :admin} = user} = Accounts.oidc_setup(identity())
      assert User.status(user) == :active
      assert Accounts.get_identity(user)
    end

    test "is refused once a user exists" do
      user_fixture()
      assert {:error, :already_set_up} = Accounts.oidc_setup(identity())
    end
  end

  describe "oidc_accept_invitation/2" do
    test "links the identity without a verified email, confirms, and expires tokens" do
      {user, token} = invited_user_fixture()

      assert {:ok, {accepted, _}} =
               Accounts.oidc_accept_invitation(token, identity(email: "other@example.com"))

      assert User.status(accepted) == :active
      assert Accounts.get_identity(user)
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "refuses an identity linked to another user, and an invalid token" do
      identity = identity()
      {:ok, _} = Accounts.link_identity(user_fixture(), identity)
      {_user, token} = invited_user_fixture()

      assert {:error, :identity_taken} = Accounts.oidc_accept_invitation(token, identity)
      assert Accounts.get_user_by_invitation_token(token)
      assert {:error, :invalid_token} = Accounts.oidc_accept_invitation("nope", identity())
    end
  end

  describe "link_identity/2 and unlink_identity/1" do
    test "links, replaces, and unlinks while a password remains" do
      user = user_fixture()

      {:ok, _} = Accounts.link_identity(user, identity(subject: "first"))
      {:ok, _} = Accounts.link_identity(user, identity(subject: "second"))
      assert Accounts.get_identity(user).subject == "second"

      assert {:ok, 1} = Accounts.unlink_identity(user)
      refute Accounts.get_identity(user)
    end

    test "an identity linked to another user cannot be linked" do
      identity = identity()
      {:ok, _} = Accounts.link_identity(user_fixture(), identity)
      assert {:error, :identity_taken} = Accounts.link_identity(user_fixture(), identity)
    end

    test "refuses to unlink the last way in" do
      {:ok, user} = Accounts.oidc_login(identity())
      previous = Application.get_env(:testfleet, TestFleet.Notifications)

      Application.put_env(
        :testfleet,
        TestFleet.Notifications,
        Keyword.put(previous, :email_enabled, false)
      )

      on_exit(fn -> Application.put_env(:testfleet, TestFleet.Notifications, previous) end)

      assert {:error, :last_login_method} = Accounts.unlink_identity(user)
      assert Accounts.get_identity(user)
    end

    test "magic links count as a way in" do
      {:ok, user} = Accounts.oidc_login(identity())
      assert Accounts.magic_link_enabled?()
      assert {:ok, 1} = Accounts.unlink_identity(user)
    end
  end
end
