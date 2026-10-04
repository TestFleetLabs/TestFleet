defmodule TestFleetWeb.UserLive.ConfirmationTest do
  # The page a magic link opens.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts

  setup do
    %{user: user_fixture()}
  end

  describe "Log in page" do
    test "renders the login buttons for an active user", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      assert has_element?(lv, "#login_form")
      assert has_element?(lv, "button[name='user[remember_me]']")
    end

    test "renders a single button for an already logged in user", %{conn: conn, user: user} do
      conn = log_in_user(conn, user)
      {token, _hashed_token} = generate_user_magic_link_token(user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      assert has_element?(lv, "#login_form")
      refute has_element?(lv, "button[name='user[remember_me]']")
    end

    test "logs the user in once", %{conn: conn, user: user} do
      {token, _hashed_token} = generate_user_magic_link_token(user)
      {:ok, lv, _html} = live(conn, ~p"/users/log-in/#{token}")

      form = form(lv, "#login_form", %{"user" => %{"token" => token}})
      render_submit(form)

      conn = follow_trigger_action(form, conn)

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
      assert get_session(conn, :user_token)
      assert Accounts.get_user!(user.id).confirmed_at == user.confirmed_at

      # log out, new conn
      conn = build_conn()

      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/#{token}")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "The login link is invalid or it has expired"
    end

    test "raises error for invalid token", %{conn: conn} do
      {:ok, _lv, html} =
        live(conn, ~p"/users/log-in/invalid-token")
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "The login link is invalid or it has expired"
    end
  end
end
