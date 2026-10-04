defmodule TestFleetWeb.NotificationEmailUnconfiguredTest do
  # Without SMTP, email channels can be saved, but say so,
  # and send nothing.
  #
  # Not async: it switches email off for the whole application.
  use TestFleetWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions
  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications

  setup :register_and_log_in_admin

  setup do
    previous = Application.fetch_env!(:testfleet, Notifications)
    Application.put_env(:testfleet, Notifications, Keyword.put(previous, :email_enabled, false))
    on_exit(fn -> Application.put_env(:testfleet, Notifications, previous) end)
  end

  test "sending fails with the reason, and nothing is sent" do
    channel = channel_fixture(kind: :email)

    assert {:error, "Email is not configured on this server"} = Notifications.send_test(channel)
    assert_no_email_sent()
  end

  test "the pages say so", %{conn: conn} do
    channel_fixture(kind: :email)

    {:ok, view, _html} = live(conn, ~p"/#{org()}/notifications")
    assert has_element?(view, "#email-unconfigured")

    {:ok, view, _html} = live(conn, ~p"/#{org()}/notifications/channels/new")
    view |> form("#channel-form", channel: %{kind: "email"}) |> render_change()
    assert has_element?(view, "#email-unconfigured")
  end
end
