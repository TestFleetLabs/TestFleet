defmodule TestFleetWeb.UserLive.InvitationTest do
  # Invitation links (Milestone 10, section 4).
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.User

  @password "a valid password"

  test "sets the password and logs in", %{conn: conn} do
    {user, token} = invited_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users/invitations/#{token}")

    # The hidden email field, as the browser submits it
    form =
      form(lv, "#invitation-form", %{
        "user" => %{
          "email" => user.email,
          "password" => @password,
          "password_confirmation" => @password
        }
      })

    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
    assert User.status(Accounts.get_user!(user.id)) == :active
  end

  test "shows validation errors and keeps the link valid", %{conn: conn} do
    {_user, token} = invited_user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/users/invitations/#{token}")

    html =
      lv
      |> form("#invitation-form", %{"user" => %{"password" => "short"}})
      |> render_submit()

    assert html =~ "should be at least 12 character(s)"
    assert Accounts.get_user_by_invitation_token(token)
  end

  test "an invalid or used link sends to the login page", %{conn: conn} do
    {:ok, _lv, html} =
      live(conn, ~p"/users/invitations/nope")
      |> follow_redirect(conn, ~p"/users/log-in")

    assert html =~ "The invitation link is invalid or it has expired."

    {_user, token} = invited_user_fixture()
    {:ok, _} = Accounts.accept_invitation(token, %{password: @password})

    assert {:error, {:live_redirect, %{to: "/users/log-in"}}} =
             live(conn, ~p"/users/invitations/#{token}")
  end
end
