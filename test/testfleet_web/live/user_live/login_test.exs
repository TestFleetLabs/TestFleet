defmodule TestFleetWeb.UserLive.LoginTest do
  # The login page (Milestone 10, section 4). Without SMTP: login_without_email_test.exs.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  describe "login page" do
    test "offers password login and, with SMTP, a magic link; no registration", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password")
      assert has_element?(lv, "#login_form_magic")
      refute has_element?(lv, "a[href='/users/register']")
    end
  end

  describe "user login - magic link" do
    test "sends magic link email when user exists", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      assert TestFleet.Repo.get_by!(TestFleet.Accounts.UserToken, user_id: user.id).context ==
               "login"
    end

    test "sends nothing to invited users, and says the same", %{conn: conn} do
      {user, _token} = invited_user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: user.email})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"

      refute TestFleet.Repo.get_by(TestFleet.Accounts.UserToken,
               user_id: user.id,
               context: "login"
             )
    end

    test "does not disclose if user is registered", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      {:ok, _lv, html} =
        form(lv, "#login_form_magic", user: %{email: "idonotexist@example.com"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~ "If your email is in our system"
    end
  end

  describe "user login - password" do
    test "redirects if user logs in with valid credentials", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password",
          user: %{email: user.email, password: valid_user_password(), remember_me: "true"}
        )

      conn = submit_form(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert conn.resp_cookies["_testfleet_user_remember_me"]
    end

    test "redirects to login page with a flash error if credentials are invalid", %{
      conn: conn
    } do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      form =
        form(lv, "#login_form_password", user: %{email: "test@email.com", password: "123456"})

      render_submit(form)

      conn = follow_trigger_action(form, conn)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "re-authentication (sudo mode)" do
    setup %{conn: conn} do
      user = user_fixture()
      %{user: user, conn: log_in_user(conn, user)}
    end

    test "shows login page with email filled in and read-only", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/users/log-in")

      assert has_element?(lv, "#login_form_password input[name='user[email]'][readonly]")
      assert has_element?(lv, "#login_form_password input[value='#{user.email}']")
      assert has_element?(lv, "#login_form_magic input[type=hidden][value='#{user.email}']")
    end
  end
end
