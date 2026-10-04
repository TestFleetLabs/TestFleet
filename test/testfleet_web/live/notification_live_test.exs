defmodule TestFleetWeb.NotificationLiveTest do
  # Channels and "Send test". Webhook URLs are credentials:
  # they must never reach the browser.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications

  setup :register_and_log_in_admin

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

      # A new channel opens its page, to choose what it receives.
      assert [%{id: id, name: "#e2e-alerts", kind: :slack, url: url}] =
               Notifications.list_channels()

      assert_redirect(view, ~p"/notifications/channels/#{id}/edit")
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

      assert [%{id: id, kind: :email, email_recipients: ["qa@example.com"]}] =
               Notifications.list_channels()

      assert_redirect(view, ~p"/notifications/channels/#{id}/edit")
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

  describe "subscriptions" do
    setup do
      project = TestFleet.ProjectsFixtures.project_fixture(name: "Portal")

      %{
        channel: channel_fixture(),
        project: project,
        environment:
          TestFleet.EnvironmentsFixtures.environment_fixture(project: project, name: "production")
      }
    end

    test "a new channel says it receives nothing, here and in the list", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/notifications/channels/#{context.channel.id}/edit")

      assert has_element?(view, "#subscriptions-empty")

      {:ok, view, _html} = live(context.conn, ~p"/notifications")

      assert has_element?(
               view,
               "#channel-#{context.channel.id}-subscriptions",
               "receives nothing yet"
             )
    end

    test "adds a subscription for all projects, with the run events preselected", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/notifications/channels/#{context.channel.id}/edit")

      assert has_element?(view, "#subscription-event-run-failing[checked]")
      refute has_element?(view, "#subscription-event-system-docker_unreachable[checked]")

      view
      |> form("#subscription-form",
        subscription: %{events: ["", "run.failing", "system.docker_unreachable"]}
      )
      |> render_submit()

      refute has_element?(view, "#subscriptions-empty")
      assert has_element?(view, "#subscription-list", "All projects")
      assert has_element?(view, "#subscription-list", "Docker unreachable")

      assert [%{project_id: nil, events: ["run.failing", "system.docker_unreachable"]}] =
               Notifications.list_subscriptions(context.channel)
    end

    test "a project scope offers its environments and no system events", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/notifications/channels/#{context.channel.id}/edit")

      refute has_element?(view, "#subscription_environment_id")
      refute has_element?(view, "#subscription-event-system-docker_unreachable[disabled]")

      view
      |> form("#subscription-form", subscription: %{project_id: context.project.id})
      |> render_change()

      assert has_element?(view, "#subscription_environment_id option", "production")
      assert has_element?(view, "#subscription-event-system-docker_unreachable[disabled]")

      view
      |> form("#subscription-form",
        subscription: %{
          project_id: context.project.id,
          environment_id: context.environment.id,
          events: ["", "run.failing", "run.recovered"]
        }
      )
      |> render_submit()

      assert has_element?(view, "#subscription-list", "Portal")
      assert has_element?(view, "#subscription-list", "production")

      assert [%{project_id: project_id, environment_id: environment_id}] =
               Notifications.list_subscriptions(context.channel)

      assert {project_id, environment_id} == {context.project.id, context.environment.id}
    end

    test "choosing no event shows an error", context do
      {:ok, view, _html} =
        live(context.conn, ~p"/notifications/channels/#{context.channel.id}/edit")

      view
      |> form("#subscription-form", subscription: %{events: [""]})
      |> render_submit()

      assert has_element?(view, "#subscription-events-error", "choose at least one event")
    end

    test "removes a subscription", context do
      {:ok, subscription} =
        Notifications.create_subscription(context.channel, %{"events" => ["run.error"]})

      {:ok, view, _html} =
        live(context.conn, ~p"/notifications/channels/#{context.channel.id}/edit")

      view |> element("#delete-subscription-#{subscription.id}") |> render_click()

      assert has_element?(view, "#subscriptions-empty")
      assert Notifications.list_subscriptions(context.channel) == []
    end
  end

  describe "deliveries" do
    test "the log shows deliveries and follows them live", %{conn: conn} do
      channel = channel_fixture(name: "Alerts")
      {:ok, view, _html} = live(conn, ~p"/notifications")

      {:ok, delivery} = Notifications.enqueue_delivery(channel, "test", "test:live")
      assert has_element?(view, "#deliveries-#{delivery.id}", "Alerts")
      assert has_element?(view, "#delivery-#{delivery.id}-status", "pending")

      {:ok, _} =
        Notifications.record_attempt(delivery, 1, {:error, :permanent, "HTTP 410"}, false)

      assert has_element?(view, "#delivery-#{delivery.id}-status", "failed")
      assert has_element?(view, "#deliveries-#{delivery.id}", "HTTP 410")

      # The delivery's channel is redacted before it reaches the page.
      refute render(view) =~ "secret-token-123"
    end

    test "the run page shows where its notifications went", %{conn: conn} do
      run = TestFleet.RunsFixtures.run_fixture(status: :failed)
      channel = channel_fixture(name: "#e2e-alerts")

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#run-notifications")

      {:ok, delivery} =
        Notifications.enqueue_delivery(channel, "run.failing", "run.failing:#{run.id}",
          run_id: run.id
        )

      assert has_element?(view, "#run-delivery-#{delivery.id}", "#e2e-alerts")

      {:ok, _} = Notifications.record_attempt(delivery, 1, :ok, false)
      assert has_element?(view, "#run-delivery-#{delivery.id}", "sent")

      # Reloaded, it is still there.
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-delivery-#{delivery.id}", "sent")
    end
  end
end
