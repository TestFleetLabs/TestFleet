defmodule TestFleetWeb.NotificationLiveTest do
  # Milestone 8, section 9: channels and "Send test". Webhook URLs are credentials:
  # they must never reach the browser.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications

  defp stub_ok, do: Req.Test.stub(TestFleet.Notifications, &Req.Test.text(&1, "ok"))

  describe "index" do
    test "shows the empty state and the navigation entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#channels-empty")
      assert has_element?(view, "#nav-notifications[aria-current=page]")
    end

    test "lists channels by their host or addresses, never their URL", %{conn: conn} do
      slack = channel_fixture(kind: :slack)
      email = channel_fixture(kind: :email, recipients_text: "qa@example.com, dev@example.com")

      {:ok, view, html} = live(conn, ~p"/notifications")

      assert has_element?(view, "#channels-#{slack.id}", "hooks.slack.com/…")
      assert has_element?(view, "#channels-#{email.id}", "qa@example.com")
      refute html =~ "secret-token-123"
    end

    test "send test reports the result", %{conn: conn} do
      stub_ok()
      channel = channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#test-channel-#{channel.id}") |> render_click()

      assert render_async(view) =~ "Test notification sent to #{channel.name}."
    end

    test "send test shows why it failed", %{conn: conn} do
      Req.Test.stub(TestFleet.Notifications, &Plug.Conn.send_resp(&1, 404, ""))
      channel = channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#test-channel-#{channel.id}") |> render_click()

      assert render_async(view) =~ "failed: HTTP 404"
    end

    test "disables and enables a channel", %{conn: conn} do
      channel = channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#toggle-channel-#{channel.id}") |> render_click()
      assert has_element?(view, "#channel-#{channel.id}-disabled")
      refute Notifications.get_channel!(channel.id).enabled

      view |> element("#toggle-channel-#{channel.id}") |> render_click()
      refute has_element?(view, "#channel-#{channel.id}-disabled")
    end

    test "deletes a channel", %{conn: conn} do
      channel = channel_fixture()
      {:ok, view, _html} = live(conn, ~p"/notifications")

      view |> element("#delete-channel-#{channel.id}") |> render_click()

      refute has_element?(view, "#channels-#{channel.id}")
      assert Notifications.get_channel(channel.id) == nil
    end
  end

  describe "form" do
    test "creates a Slack channel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications/channels/new")

      # The URL field appears once a kind is chosen.
      refute has_element?(view, "#channel_url")
      view |> form("#channel-form", channel: %{kind: "slack"}) |> render_change()
      assert has_element?(view, "#channel_url")

      view
      |> form("#channel-form", channel: %{name: "#e2e-alerts", kind: "slack", url: slack_url()})
      |> render_submit()

      assert_redirect(view, ~p"/notifications")
      assert [%{name: "#e2e-alerts", kind: :slack, url: url}] = Notifications.list_channels()
      assert url == slack_url()
    end

    test "creates an email channel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications/channels/new")
      view |> form("#channel-form", channel: %{kind: "email"}) |> render_change()

      view
      |> form("#channel-form",
        channel: %{name: "QA", kind: "email", recipients_text: "qa@example.com"}
      )
      |> render_submit()

      assert_redirect(view, ~p"/notifications")

      assert [%{kind: :email, email_recipients: ["qa@example.com"]}] =
               Notifications.list_channels()
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications/channels/new")
      view |> form("#channel-form", channel: %{kind: "webhook"}) |> render_change()

      html =
        view
        |> form("#channel-form", channel: %{name: "Hook", kind: "webhook", url: "ftp://x"})
        |> render_submit()

      assert html =~ "must start with https:// or http://"
    end

    test "editing never shows the URL or the secret, and keeps them when left empty",
         %{conn: conn} do
      channel = channel_fixture(kind: :webhook, signing_secret: "a-long-signing-secret")

      {:ok, view, html} = live(conn, ~p"/notifications/channels/#{channel.id}/edit")

      refute html =~ "token=abc123"
      refute html =~ "a-long-signing-secret"
      assert has_element?(view, "#channel-kind")
      assert has_element?(view, "#channel_clear_signing_secret")
      assert html =~ "hooks.example.com/…"

      # A failed save must not bring the stored secrets into the form either.
      html =
        view
        |> form("#channel-form", channel: %{name: "", url: "", signing_secret: ""})
        |> render_submit()

      refute html =~ "token=abc123"
      refute html =~ "a-long-signing-secret"

      view
      |> form("#channel-form", channel: %{name: "Renamed", url: "", signing_secret: ""})
      |> render_submit()

      assert_redirect(view, ~p"/notifications")
      stored = Notifications.get_channel!(channel.id)
      assert stored.name == "Renamed"
      assert stored.url == channel.url
      assert stored.signing_secret == "a-long-signing-secret"
    end

    test "send test uses the form's values before saving", %{conn: conn} do
      test = self()

      Req.Test.stub(TestFleet.Notifications, fn conn ->
        send(test, {:host, conn.host})
        Req.Test.text(conn, "ok")
      end)

      {:ok, view, _html} = live(conn, ~p"/notifications/channels/new")
      view |> form("#channel-form", channel: %{kind: "webhook"}) |> render_change()

      view
      |> form("#channel-form",
        channel: %{name: "Hook", kind: "webhook", url: "https://receiver.example.com/hook"}
      )
      |> render_change()

      view |> element("#send-test") |> render_click()
      render_async(view)

      assert has_element?(view, "#test-ok")
      assert_received {:host, "receiver.example.com"}
      assert Notifications.list_channels() == []
    end

    test "send test on an invalid form asks to fix it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/notifications/channels/new")

      view |> element("#send-test") |> render_click()
      render_async(view)

      assert has_element?(view, "#test-error", "Fix the form first.")
    end
  end
end
