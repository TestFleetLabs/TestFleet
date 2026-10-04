defmodule TestFleetWeb.OrganizationRoutesTest do
  # Pages live under /:org; the ways into an organization; its settings.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures
  import TestFleet.OrganizationsFixtures
  import TestFleet.RunsFixtures

  alias TestFleet.{Accounts, Organizations}

  describe "a member" do
    setup :register_and_log_in_user

    test "/ opens their organization", %{conn: conn} do
      assert conn |> get(~p"/") |> redirected_to() == ~p"/#{org()}"
    end

    test "an organization they do not belong to is not found", %{conn: conn} do
      other = organization_fixture()

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/#{other}") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/#{other}/projects") end
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/no-such-organization/runs") end
    end

    test "/runs/:id, from links sent before, opens the run in its organization", %{conn: conn} do
      run = run_fixture()
      assert conn |> get(~p"/runs/#{run.id}") |> redirected_to() == ~p"/#{org()}/runs/#{run.id}"
    end

    test "/runs/:id of another organization's run, or no run, is 404", %{conn: conn} do
      other = organization_fixture()
      run = run_fixture(project: TestFleet.ProjectsFixtures.project_fixture(organization: other))

      assert conn |> get(~p"/runs/#{run.id}") |> html_response(404)
      assert conn |> get(~p"/runs/999999999999") |> html_response(404)
      assert conn |> get(~p"/runs/nope") |> html_response(404)
    end

    test "sees the organization's name, without a switcher", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/#{org()}")
      assert has_element?(lv, "#organization", org().name)
      refute has_element?(lv, "#organization-switch")
    end
  end

  describe "the organization list" do
    test "/ opens it with several organizations, and it lists them", %{conn: conn} do
      user = user_fixture()
      other = organization_fixture(name: "Second")
      {:ok, _} = Organizations.put_membership(user, other, :admin)
      conn = log_in_user(conn, user)

      assert conn |> get(~p"/") |> redirected_to() == ~p"/organizations"

      {:ok, lv, _html} = live(conn, ~p"/organizations")
      assert has_element?(lv, "#organization-#{org().slug}")
      assert has_element?(lv, "#organization-#{other.slug}", "Admin")
    end

    test "says so when the user belongs to none", %{conn: conn} do
      user = user_fixture()
      TestFleet.Repo.delete_all(TestFleet.Organizations.Membership)
      {:ok, lv, _html} = conn |> log_in_user(user) |> live(~p"/organizations")

      assert has_element?(lv, "#organizations-empty")
    end
  end

  describe "organization settings" do
    setup :register_and_log_in_admin

    test "renames the organization and moves to its new URL", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/#{org()}/settings")

      assert {:error, {:live_redirect, %{to: "/acme/settings"}}} =
               lv
               |> form("#organization-form", organization: %{name: "ACME", slug: "acme"})
               |> render_submit()

      assert %{name: "ACME", slug: "acme"} = Organizations.single()
    end

    test "refuses a reserved slug", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/#{org()}/settings")

      html =
        lv
        |> form("#organization-form", organization: %{name: "X", slug: "users"})
        |> render_submit()

      assert html =~ "is reserved"
    end
  end

  describe "the Members page" do
    setup :register_and_log_in_admin

    test "lists only the organization's members", %{conn: conn} do
      outsider = user_fixture(organization: organization_fixture())
      {:ok, lv, _html} = live(conn, ~p"/#{org()}/members")

      refute has_element?(lv, "#users-#{outsider.id}")
      assert_raise Ecto.NoResultsError, fn -> Accounts.get_member!(org_scope(), outsider.id) end
    end

    test "counts only the organization's API tokens", %{conn: conn} do
      other = organization_fixture()
      user = user_fixture()
      {:ok, _} = Organizations.put_membership(user, other, :member)
      api_token_fixture(user)

      {:ok, _} =
        Accounts.create_api_token(
          TestFleet.Accounts.Scope.put_organization(%TestFleet.Accounts.Scope{user: user}, other),
          %{
            name: "elsewhere"
          }
        )

      {:ok, lv, _html} = live(conn, ~p"/#{org()}/members")
      assert has_element?(lv, "#user-api-tokens-#{user.id}", "1 API token")
    end
  end

  test "links that TestFleet sends carry the organization", %{} do
    run = TestFleet.Runs.get_run!(run_fixture().id)

    message =
      TestFleet.Notifications.Message.run_event("run.failing", run, %{}, %{names: [], count: 0})

    assert message.link.url =~ "/#{org().slug}/runs/#{run.id}"
    assert TestFleetWeb.API.RunJSON.show(%{run: run}).url =~ "/#{org().slug}/runs/#{run.id}"
  end
end
