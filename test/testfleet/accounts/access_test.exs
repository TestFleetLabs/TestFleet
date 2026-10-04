defmodule TestFleet.Accounts.AccessTest do
  # First-run setup, invitations, roles, and deactivation.
  # Not async: one test turns email off in the application environment.
  use TestFleet.DataCase, async: false

  import Swoosh.TestAssertions
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{User, UserToken}
  alias TestFleet.Notifications

  @password "a valid password"

  describe "first-run setup" do
    test "the token is stable until restart and only valid while there is no user" do
      token = Accounts.setup_token()
      assert token == Accounts.setup_token()
      assert Accounts.valid_setup_token?(token)
      refute Accounts.valid_setup_token?("wrong")
      refute Accounts.valid_setup_token?(nil)

      user_fixture()
      refute Accounts.setup_needed?()
      refute Accounts.valid_setup_token?(token)
    end

    test "creates an active, confirmed admin" do
      assert {:ok, user} =
               Accounts.create_first_admin(%{
                 email: "first@example.com",
                 password: @password,
                 password_confirmation: @password
               })

      assert user.role == :admin
      assert User.status(user) == :active
      assert Accounts.get_user_by_email_and_password("first@example.com", @password)
    end

    test "validates email and password" do
      assert {:error, changeset} = Accounts.create_first_admin(%{email: "x", password: "short"})
      assert %{email: [_], password: [_]} = errors_on(changeset)
    end

    test "a second setup is refused" do
      attrs = %{email: "first@example.com", password: @password}
      assert {:ok, _} = Accounts.create_first_admin(attrs)

      assert {:error, :already_set_up} =
               Accounts.create_first_admin(%{attrs | email: "second@example.com"})

      assert [_one] = Accounts.list_users()
    end
  end

  describe "invitations" do
    test "the link sets a password, confirms the user, and expires all tokens" do
      {user, token} = invited_user_fixture()
      assert Accounts.get_user_by_invitation_token(token).id == user.id

      assert {:ok, {accepted, _expired}} =
               Accounts.accept_invitation(token, %{password: @password})

      assert User.status(accepted) == :active
      assert Accounts.get_user_by_email_and_password(user.email, @password)
      refute Repo.get_by(UserToken, user_id: user.id)
      assert {:error, :invalid_token} = Accounts.accept_invitation(token, %{password: @password})
    end

    test "invited users cannot log in before accepting" do
      {user, _token} = invited_user_fixture()
      refute Accounts.get_user_by_email_and_password(user.email, @password)
    end

    test "validates the password and keeps the invitation" do
      {_user, token} = invited_user_fixture()
      assert {:error, changeset} = Accounts.accept_invitation(token, %{password: "short"})
      assert %{password: [_]} = errors_on(changeset)
      assert Accounts.get_user_by_invitation_token(token)
    end

    test "expire after 7 days" do
      {_user, token} = invited_user_fixture()
      Repo.update_all(UserToken, set: [inserted_at: DateTime.add(DateTime.utc_now(), -8, :day)])
      refute Accounts.get_user_by_invitation_token(token)
    end

    test "a new link replaces the old one" do
      {user, old} = invited_user_fixture()
      assert {:ok, %{url: new}} = Accounts.renew_invitation(user, & &1)
      refute Accounts.get_user_by_invitation_token(old)
      assert Accounts.get_user_by_invitation_token(new)
    end

    test "revoking deletes the invited user" do
      {user, token} = invited_user_fixture()
      assert {:ok, _} = Accounts.revoke_invitation(user)
      refute Repo.get(User, user.id)
      refute Accounts.get_user_by_invitation_token(token)
    end

    test "only pending invitations can be renewed or revoked" do
      user = user_fixture()
      assert {:error, :not_invited} = Accounts.renew_invitation(user, & &1)
      assert {:error, :not_invited} = Accounts.revoke_invitation(user)
    end

    test "are emailed with SMTP" do
      {:ok, %{user: user, url: url, emailed?: true}} =
        Accounts.invite_user(%{email: unique_user_email(), role: :member}, &"https://tf/#{&1}")

      assert_email_sent(fn email ->
        assert email.to == [{"", user.email}]
        assert email.text_body =~ url
      end)
    end

    test "are not emailed without SMTP" do
      previous = Application.get_env(:testfleet, Notifications)
      Application.put_env(:testfleet, Notifications, Keyword.put(previous, :email_enabled, false))
      on_exit(fn -> Application.put_env(:testfleet, Notifications, previous) end)

      assert {:ok, %{emailed?: false}} =
               Accounts.invite_user(%{email: unique_user_email(), role: :member}, & &1)

      assert_no_email_sent()
    end
  end

  describe "roles" do
    test "an admin can be demoted while another admin is active" do
      admin = admin_fixture()
      _other = admin_fixture()
      assert {:ok, %{role: :member}} = Accounts.update_user_role(admin, :member)
    end

    test "the last active admin cannot be demoted or deactivated" do
      admin = admin_fixture()
      # Neither an invited nor a deactivated admin counts.
      invited_user_fixture(role: :admin)
      admin_fixture() |> Accounts.deactivate_user()

      assert {:error, :last_admin} = Accounts.update_user_role(admin, :member)
      assert {:error, :last_admin} = Accounts.deactivate_user(admin)
    end

    test "members can be promoted" do
      assert {:ok, %{role: :admin}} = Accounts.update_user_role(user_fixture(), :admin)
    end
  end

  describe "deactivation" do
    test "refuses login, deletes the tokens, and can be undone" do
      admin_fixture()
      user = user_fixture()
      session = Accounts.generate_user_session_token(user)

      assert {:ok, {user, [%UserToken{context: "session"}]}} = Accounts.deactivate_user(user)
      assert User.status(user) == :deactivated
      refute Accounts.get_user_by_session_token(session)
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      assert {:ok, user} = Accounts.reactivate_user(user)
      assert Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "invite_admin/2 (release command)" do
    test "creates a new admin with a working link" do
      assert {:ok, token} = Accounts.invite_admin("ops@example.com", & &1)
      assert {:ok, {user, _}} = Accounts.accept_invitation(token, %{password: @password})
      assert user.role == :admin
      assert User.status(user) == :active
    end

    test "restores a deactivated member as an admin with a new password" do
      admin_fixture()
      user = deactivated_user_fixture()

      assert {:ok, token} = Accounts.invite_admin(user.email, & &1)
      assert {:ok, {user, _}} = Accounts.accept_invitation(token, %{password: @password})
      assert user.role == :admin
      assert Accounts.get_user_by_email_and_password(user.email, @password)
    end
  end

  test "record_login/1 sets the last login" do
    user = user_fixture()
    assert :ok = Accounts.record_login(user)
    assert %DateTime{} = Repo.get!(User, user.id).last_login_at
  end
end
