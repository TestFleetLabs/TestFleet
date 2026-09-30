defmodule TestFleetWeb.AccessTest do
  # Every page behind a login, admin pages behind the admin role (Milestone 10,
  # sections 5 and 6).
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  # Open without a session; everything else in the router must redirect to the login.
  @open [
    {"GET", "/users/log-in"},
    {"GET", "/users/log-in/:token"},
    {"GET", "/users/invitations/:token"},
    {"GET", "/setup"},
    {"POST", "/users/log-in"},
    {"DELETE", "/users/log-out"}
  ]

  @admin_pages ~w(/registries /registries/new /notifications /notifications/channels/new /users)

  test "every route requires a login, except the open ones", %{conn: conn} do
    routes =
      TestFleetWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.reject(&String.starts_with?(&1.path, "/dev"))
      |> Enum.reject(&({String.upcase(to_string(&1.verb)), &1.path} in @open))

    assert length(routes) > 20

    for route <- routes do
      path = String.replace(route.path, ~r/[:*]\w+/, "1")
      conn = dispatch(conn, TestFleetWeb.Endpoint, route.verb, path)

      assert redirected_to(conn) == ~p"/users/log-in",
             "#{route.verb} #{route.path} must require a login"
    end
  end

  describe "a member" do
    setup :register_and_log_in_user

    test "is sent from every admin page to the dashboard", %{conn: conn} do
      for path <- @admin_pages do
        assert {:error, {:redirect, %{to: "/", flash: %{"error" => _}}}} = live(conn, path),
               "#{path} must be admin only"
      end
    end

    test "does not see the admin pages in the navigation", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/")

      for key <- ~w(dashboard projects runs), do: assert(has_element?(lv, "#nav-#{key}"))
      for key <- ~w(registries notifications users), do: refute(has_element?(lv, "#nav-#{key}"))
      assert has_element?(lv, "#user-menu-log-out")
    end
  end

  describe "an admin" do
    setup :register_and_log_in_admin

    test "opens the admin pages and sees them in the navigation", %{conn: conn} do
      for path <- @admin_pages, do: assert({:ok, _lv, _html} = live(conn, path))

      {:ok, lv, _html} = live(conn, ~p"/")
      for key <- ~w(registries notifications users), do: assert(has_element?(lv, "#nav-#{key}"))
    end
  end

  test "a deactivated user's session no longer works", %{conn: conn} do
    admin_fixture()
    user = user_fixture()
    conn = log_in_user(conn, user)
    {:ok, _} = TestFleet.Accounts.deactivate_user(user)

    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/")
  end
end
