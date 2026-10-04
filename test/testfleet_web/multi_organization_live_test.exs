defmodule TestFleetWeb.MultiOrganizationLiveTest do
  # The pages in :multi mode. Not async: it switches the mode for the application.
  use TestFleetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures
  import TestFleet.OrganizationsFixtures

  alias TestFleet.{Accounts, Organizations}

  setup %{conn: conn, organization: organization} do
    previous = Application.get_env(:testfleet, :organizations)
    on_exit(fn -> Application.put_env(:testfleet, :organizations, previous) end)

    admin = admin_fixture()
    other = organization_fixture(name: "Second")
    {:ok, _} = Organizations.put_membership(admin, other, :member)

    Application.put_env(:testfleet, :organizations, :multi)

    %{
      conn: log_in_user(conn, admin, token_authenticated_at: DateTime.utc_now(:second)),
      admin: admin,
      ours: organization,
      other: other
    }
  end

  test "the navigation offers to switch organizations", %{conn: conn, ours: ours} do
    {:ok, lv, _html} = live(conn, ~p"/#{ours}")
    assert has_element?(lv, "#organization-switch", ours.name)
  end

  test "roles belong to the membership", %{conn: conn, ours: ours, other: other} do
    {:ok, lv, _html} = live(conn, ~p"/#{ours}")
    assert has_element?(lv, "#nav-members")

    {:ok, lv, _html} = live(conn, ~p"/#{other}")
    refute has_element?(lv, "#nav-members")
    assert {:error, {:redirect, _}} = live(conn, ~p"/#{other}/members")
  end

  test "members are removed, not deactivated", %{conn: conn, ours: ours} do
    member = user_fixture(organization: ours)
    api_token_fixture(member, organization: ours)

    {:ok, lv, _html} = live(conn, ~p"/#{ours}/members")
    refute has_element?(lv, "#deactivate-#{member.id}")

    lv |> element("#remove-#{member.id}") |> render_click()

    refute has_element?(lv, "#users-#{member.id}")
    refute Organizations.get_membership(member, ours)
    assert Accounts.list_api_tokens(%TestFleet.Accounts.Scope{user: member}) == []
    assert Accounts.get_user!(member.id).deactivated_at == nil
  end

  test "the last admin cannot be removed", %{conn: conn, ours: ours, admin: admin} do
    other_admin = user_fixture(organization: ours, role: :admin)
    {:ok, lv, _html} = live(conn, ~p"/#{ours}/members")

    lv |> element("#remove-#{other_admin.id}") |> render_click()
    refute Organizations.get_membership(other_admin, ours)
    assert {:error, :last_admin} = Accounts.remove_member(org_scope(ours), admin)
  end

  test "a new API token is for the organization chosen in the form", %{
    conn: conn,
    admin: admin,
    other: other
  } do
    {:ok, lv, _html} = live(conn, ~p"/users/settings")

    lv
    |> form("#api-token-form", api_token: %{name: "elsewhere", organization_id: other.id})
    |> render_submit()

    [api_token] = Accounts.list_api_tokens(%TestFleet.Accounts.Scope{user: admin})
    assert api_token.organization_id == other.id
  end
end
