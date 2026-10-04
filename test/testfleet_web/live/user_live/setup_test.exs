defmodule TestFleetWeb.UserLive.SetupTest do
  # First-run setup.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts

  @password "a valid password"

  test "is 404 without the token or with a wrong one", %{conn: conn} do
    assert_raise TestFleetWeb.NotFoundError, fn -> live(conn, ~p"/setup") end
    assert_raise TestFleetWeb.NotFoundError, fn -> live(conn, ~p"/setup?token=wrong") end
  end

  test "is 404 once a user exists", %{conn: conn} do
    user_fixture()

    assert_raise TestFleetWeb.NotFoundError, fn ->
      live(conn, ~p"/setup?token=#{Accounts.setup_token()}")
    end
  end

  test "creates the first admin and logs in", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")

    params = %{
      "user" => %{
        "email" => "first@example.com",
        "password" => @password,
        "password_confirmation" => @password
      }
    }

    form = form(lv, "#setup-form", params)
    render_submit(form)
    conn = follow_trigger_action(form, conn)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_token)
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome to TestFleet!"
    assert "first@example.com" |> Accounts.get_user_by_email() |> role() == :admin
  end

  test "shows validation errors", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")

    html =
      lv
      |> form("#setup-form", %{"user" => %{"email" => "nope", "password" => "short"}})
      |> render_change()

    assert html =~ "must have the @ sign"
    assert html =~ "should be at least 12 character(s)"
  end
end
