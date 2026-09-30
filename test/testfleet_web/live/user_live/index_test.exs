defmodule TestFleetWeb.UserLive.IndexTest do
  # The Users page (Milestone 10, section 9).
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.User

  setup :register_and_log_in_admin

  test "lists users with role and status; no actions on oneself", %{conn: conn, user: admin} do
    member = user_fixture()
    {invited, _token} = invited_user_fixture()

    {:ok, lv, _html} = live(conn, ~p"/users")

    assert has_element?(lv, "#users-#{admin.id}")
    assert has_element?(lv, "#user-status-#{member.id}", "Active")
    assert has_element?(lv, "#user-status-#{invited.id}", "Invited")
    refute has_element?(lv, "#deactivate-#{admin.id}")
    refute has_element?(lv, "#role-#{admin.id}")
  end

  test "invites a user and shows the link once", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/users")

    lv
    |> form("#invite-form", %{"user" => %{"email" => "new@example.com", "role" => "admin"}})
    |> render_submit()

    user = Accounts.get_user_by_email("new@example.com")
    assert %User{role: :admin} = user
    assert has_element?(lv, "#users-#{user.id}")
    assert has_element?(lv, "#invite-link")

    url =
      lv |> element("#invite-link-url") |> render() |> then(&Regex.run(~r/value="([^"]+)"/, &1))

    [_, url] = url
    token = url |> URI.parse() |> Map.fetch!(:path) |> Path.basename()
    assert Accounts.get_user_by_invitation_token(token).id == user.id
    assert_email_sent(to: "new@example.com")

    lv |> element("#dismiss-invite-link") |> render_click()
    refute has_element?(lv, "#invite-link")
  end

  test "shows invitation errors", %{conn: conn, user: admin} do
    {:ok, lv, _html} = live(conn, ~p"/users")

    html =
      lv
      |> form("#invite-form", %{"user" => %{"email" => admin.email, "role" => "member"}})
      |> render_submit()

    assert html =~ "has already been taken"
  end

  test "renews and revokes a pending invitation", %{conn: conn} do
    {user, old} = invited_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users")

    lv |> element("#renew-#{user.id}") |> render_click()
    assert has_element?(lv, "#invite-link")
    refute Accounts.get_user_by_invitation_token(old)

    lv |> element("#revoke-#{user.id}") |> render_click()
    refute has_element?(lv, "#users-#{user.id}")
    refute has_element?(lv, "#invite-link")
  end

  test "changes roles", %{conn: conn} do
    member = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users")

    lv |> element("#role-#{member.id}") |> render_click()
    assert Accounts.get_user!(member.id).role == :admin

    lv |> element("#role-#{member.id}") |> render_click()
    assert Accounts.get_user!(member.id).role == :member
  end

  test "deactivating disconnects the user's pages; reactivating lets them back", %{conn: conn} do
    member = user_fixture()
    token = Accounts.generate_user_session_token(member)
    member_conn = build_conn() |> init_test_session(%{user_token: token})

    # LiveViewTest has no transport socket: assert the broadcast that closes it.
    TestFleetWeb.Endpoint.subscribe("users_sessions:#{Base.url_encode64(token)}")

    {:ok, lv, _html} = live(conn, ~p"/users")
    lv |> element("#deactivate-#{member.id}") |> render_click()

    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert has_element?(lv, "#user-status-#{member.id}", "Deactivated")
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(member_conn, ~p"/runs")

    lv |> element("#reactivate-#{member.id}") |> render_click()
    assert has_element?(lv, "#user-status-#{member.id}", "Active")
  end
end
