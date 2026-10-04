defmodule TestFleetWeb.UserLive.WithoutEmailTest do
  # Without SMTP: no magic links, no email change, and
  # invitation links are only shown. Not async: turns email off in the application
  # environment.
  use TestFleetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import TestFleet.AccountsFixtures

  alias TestFleet.Notifications

  setup do
    previous = Application.get_env(:testfleet, Notifications)
    Application.put_env(:testfleet, Notifications, Keyword.put(previous, :email_enabled, false))
    on_exit(fn -> Application.put_env(:testfleet, Notifications, previous) end)
  end

  test "the login page offers only the password", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users/log-in")

    assert has_element?(lv, "#login_form_password")
    refute has_element?(lv, "#login_form_magic")
  end

  test "the settings offer no email change", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")

    assert has_element?(lv, "#password_form")
    refute has_element?(lv, "#email_form")
  end

  test "an invitation link is shown, not emailed", %{conn: conn} do
    {:ok, lv, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/#{org()}/members")

    lv
    |> form("#invite-form", %{"user" => %{"email" => "new@example.com", "role" => "member"}})
    |> render_submit()

    assert has_element?(lv, "#invite-link", "Send this link to new@example.com")
    assert_no_email_sent()
  end
end
