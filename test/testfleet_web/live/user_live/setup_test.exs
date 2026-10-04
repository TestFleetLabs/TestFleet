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

  @tag :no_organization
  test "on a fresh installation, names the organization it creates", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")
    assert has_element?(lv, "#user_organization_name")

    form =
      form(lv, "#setup-form", %{
        "user" => %{
          "organization_name" => "ACME QA",
          "email" => "first@example.com",
          "password" => @password,
          "password_confirmation" => @password
        }
      })

    render_submit(form)
    follow_trigger_action(form, conn)

    assert %{name: "ACME QA", slug: "acme-qa"} = TestFleet.Organizations.single()
  end

  @tag :no_organization
  test "refuses an organization name whose URL name is reserved", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")

    html =
      lv
      |> form("#setup-form", %{
        "user" => %{
          "organization_name" => "Users",
          "email" => "first@example.com",
          "password" => @password,
          "password_confirmation" => @password
        }
      })
      |> render_submit()

    assert html =~ "is reserved"
    refute TestFleet.Organizations.single()
    refute Accounts.get_user_by_email("first@example.com")
  end

  test "an installation that has its organization does not ask for one", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/setup?token=#{Accounts.setup_token()}")
    refute has_element?(lv, "#user_organization_name")
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
