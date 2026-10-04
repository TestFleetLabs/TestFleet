defmodule TestFleetWeb.UserLive.SSOOnlyTest do
  # "SSO button only" with AUTH_PASSWORD_LOGIN=false.
  # Not async: turns password login off in the application environment.
  use TestFleetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts

  setup do
    previous = Application.get_env(:testfleet, Accounts)
    Application.put_env(:testfleet, Accounts, Keyword.put(previous, :password_login, false))
    on_exit(fn -> Application.put_env(:testfleet, Accounts, previous) end)
  end

  test "the login page shows only the provider", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    assert has_element?(lv, "#oidc-login", "Log in with Company SSO")
    refute has_element?(lv, "#login_form_password")
    refute has_element?(lv, "#login_form_magic")
  end

  test "password and magic-link logins are refused", %{conn: conn} do
    user = user_fixture()
    {token, _hashed} = generate_user_magic_link_token(user)

    for params <- [
          %{"user" => %{"email" => user.email, "password" => valid_user_password()}},
          %{"user" => %{"token" => token}}
        ] do
      conn = post(conn, ~p"/users/log-in", params)
      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "single sign-on"
    end
  end

  test "setup and invitations offer only the provider", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")
    assert has_element?(lv, "#oidc-setup")
    refute has_element?(lv, "#setup-form")

    {_user, token} = invited_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users/invitations/#{token}")
    assert has_element?(lv, "#oidc-invite")
    refute has_element?(lv, "#invitation-form")
  end

  test "the settings have no password section", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")

    assert has_element?(lv, "#sso")
    refute has_element?(lv, "#password_form")
  end
end
