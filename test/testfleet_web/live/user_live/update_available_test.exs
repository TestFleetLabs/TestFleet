defmodule TestFleetWeb.UserLive.UpdateAvailableTest do
  # The newer TestFleet release: a dot on the settings icon and an alert on the
  # settings page, for admins.
  #
  # Not async: the newer release is kept in :persistent_term for the whole
  # application.
  use TestFleetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures

  alias TestFleet.UpdateCheck

  @release_url "https://github.com/testfleetlabs/testfleet/releases/tag/v99.0.0"

  setup context do
    Req.Test.set_req_test_to_shared(context)
    on_exit(fn -> :persistent_term.erase({UpdateCheck, :available}) end)
  end

  defp newer_release do
    Req.Test.stub(
      UpdateCheck,
      &Req.Test.json(&1, %{"tag_name" => "v99.0.0", "html_url" => @release_url})
    )

    start_supervised!({UpdateCheck, enabled: true, name: :update_available_test})
    assert %{version: "99.0.0"} = UpdateCheck.check(:update_available_test)
  end

  test "an admin sees the dot and the alert with both versions and the release", %{conn: conn} do
    newer_release()
    {:ok, view, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/users/settings")

    assert has_element?(view, "#user-menu-update-dot")
    assert has_element?(view, "#mobile-user-menu-update-dot")
    assert has_element?(view, "#update-available", "99.0.0")
    assert has_element?(view, "#update-available", UpdateCheck.current_version())
    assert has_element?(view, ~s(#update-release-link[href="#{@release_url}"][target="_blank"]))
  end

  test "a member sees neither", %{conn: conn} do
    newer_release()
    {:ok, view, _html} = conn |> log_in_user(user_fixture()) |> live(~p"/users/settings")

    refute has_element?(view, "#user-menu-update-dot")
    refute has_element?(view, "#update-available")
  end

  test "without a newer release, there is neither", %{conn: conn} do
    {:ok, view, _html} = conn |> log_in_user(admin_fixture()) |> live(~p"/users/settings")

    refute has_element?(view, "#user-menu-update-dot")
    refute has_element?(view, "#update-available")
  end
end
