defmodule TestFleet.NotificationsTest do
  # Channels and deliveries.
  use TestFleet.DataCase, async: true

  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Channel, Delivery, DeliveryWorker}

  describe "channels" do
    test "a URL is encrypted at rest, and only its host is kept in the clear" do
      channel = channel_fixture(kind: :slack)

      %{rows: [[raw, hint]]} =
        Repo.query!(
          "SELECT url_encrypted, url_hint FROM notification_channels WHERE id = $1",
          [channel.id]
        )

      refute raw =~ "secret-token"
      assert hint == "hooks.slack.com/…"
      assert Notifications.get_channel!(channel.id).url == slack_url()
    end

    test "the signing secret is encrypted too" do
      channel = channel_fixture(kind: :webhook, signing_secret: "a-long-signing-secret")

      %{rows: [[raw]]} =
        Repo.query!(
          "SELECT signing_secret_encrypted FROM notification_channels WHERE id = $1",
          [channel.id]
        )

      refute raw =~ "a-long-signing-secret"
    end

    test "redact removes the secrets and says whether a signing secret exists" do
      channel = channel_fixture(kind: :webhook, signing_secret: "a-long-signing-secret")

      assert %Channel{url: nil, signing_secret: nil, signing_secret_set: true} =
               Notifications.redact(channel)

      # `redact: true` keeps the secrets out of inspect, and so out of logs.
      refute inspect(channel) =~ "token=abc123"
      refute inspect(channel) =~ "a-long-signing-secret"
    end

    test "editing with an empty URL or secret keeps the stored ones" do
      channel = channel_fixture(kind: :webhook, signing_secret: "a-long-signing-secret")

      {:ok, updated} =
        Notifications.update_channel(channel, %{
          "name" => "Renamed",
          "url" => "",
          "signing_secret" => ""
        })

      assert updated.url == channel.url
      assert updated.signing_secret == "a-long-signing-secret"
    end

    test "the signing secret can be removed" do
      channel = channel_fixture(kind: :webhook, signing_secret: "a-long-signing-secret")

      {:ok, updated} = Notifications.update_channel(channel, %{"clear_signing_secret" => "true"})

      assert updated.signing_secret == nil
      assert updated.url == channel.url
    end

    test "a new URL channel needs a URL" do
      assert {:error, changeset} = Notifications.create_channel(%{name: "Slack", kind: :slack})
      assert "can't be blank" in errors_on(changeset).url
    end

    test "URLs must be http(s) with a host" do
      for url <- ["ftp://example.com/hook", "hooks.slack.com/services/x", "https://"] do
        assert {:error, changeset} =
                 Notifications.create_channel(%{name: "Hook", kind: :webhook, url: url})

        assert errors_on(changeset).url != [], "accepted #{url}"
      end
    end

    test "a URL without a path is hinted by its host alone" do
      channel = channel_fixture(kind: :webhook, url: "http://receiver:8080")
      assert channel.url_hint == "receiver"
    end

    test "email recipients are split, deduplicated, and checked" do
      channel =
        channel_fixture(
          kind: :email,
          recipients_text: "qa@example.com, dev@example.com\nqa@example.com"
        )

      assert channel.email_recipients == ["qa@example.com", "dev@example.com"]
      assert channel.url == nil

      assert {:error, changeset} =
               Notifications.create_channel(%{
                 name: "Mail",
                 kind: :email,
                 recipients_text: "qa@example.com, not-an-address"
               })

      assert ["not an email address: not-an-address"] = errors_on(changeset).recipients_text

      assert {:error, changeset} =
               Notifications.create_channel(%{name: "Mail", kind: :email, recipients_text: " "})

      assert ["enter at least one address"] = errors_on(changeset).recipients_text

      many = Enum.map_join(1..21, ",", &"user#{&1}@example.com")

      assert {:error, changeset} =
               Notifications.create_channel(%{name: "Mail", kind: :email, recipients_text: many})

      assert ["at most 20 addresses"] = errors_on(changeset).recipients_text
    end

    test "names are unique, ignoring case" do
      channel_fixture(name: "E2E Alerts")

      assert {:error, changeset} =
               Notifications.create_channel(%{name: "e2e alerts", kind: :slack, url: slack_url()})

      assert "is already used by another channel" in errors_on(changeset).name
    end

    test "the kind cannot change" do
      channel = channel_fixture(kind: :slack)
      {:ok, updated} = Notifications.update_channel(channel, %{"kind" => "email"})
      assert updated.kind == :slack
    end

    test "a secret is too short below 16 characters" do
      assert {:error, changeset} =
               Notifications.create_channel(%{
                 name: "Hook",
                 kind: :webhook,
                 url: "https://example.com/hook",
                 signing_secret: "short"
               })

      assert errors_on(changeset).signing_secret != []
    end
  end

  describe "send_test/2" do
    test "sends with the form's values, falling back to the stored URL" do
      channel = channel_fixture(kind: :slack)
      test = self()

      Req.Test.stub(TestFleet.Notifications, fn conn ->
        send(test, {:url, "#{conn.scheme}://#{conn.host}#{conn.request_path}"})
        Req.Test.text(conn, "ok")
      end)

      assert :ok = Notifications.send_test(channel, %{"name" => "Renamed", "url" => ""})
      assert_received {:url, "https://hooks.slack.com/services/T000/B000/secret-token-123"}
    end

    test "reports the failure without the URL" do
      Req.Test.stub(TestFleet.Notifications, &Plug.Conn.send_resp(&1, 404, "no_team"))

      assert {:error, "HTTP 404"} =
               Notifications.send_test(%Channel{}, %{
                 "name" => "New",
                 "kind" => "slack",
                 "url" => slack_url()
               })
    end

    test "an invalid form is not sent" do
      assert {:error, "Fix the form first."} =
               Notifications.send_test(%Channel{}, %{"name" => "x"})
    end
  end

  describe "deliveries" do
    test "enqueue_delivery stores the delivery and a job that holds only its id" do
      channel = channel_fixture()

      assert {:ok, %Delivery{id: id, status: :pending}} =
               Notifications.enqueue_delivery(channel, "test", "test:1")

      assert [job] = all_enqueued(worker: DeliveryWorker)
      assert job.args == %{"delivery_id" => id}
    end

    test "a second delivery with the same key is not created" do
      channel = channel_fixture()

      {:ok, _} = Notifications.enqueue_delivery(channel, "test", "test:1")
      assert {:ok, :duplicate} = Notifications.enqueue_delivery(channel, "test", "test:1")

      assert [_] = all_enqueued(worker: DeliveryWorker)
      assert Repo.aggregate(Delivery, :count) == 1
    end

    test "prune_deliveries deletes those created before the cutoff" do
      channel = channel_fixture()
      {:ok, old} = Notifications.enqueue_delivery(channel, "test", "test:old")
      {:ok, recent} = Notifications.enqueue_delivery(channel, "test", "test:recent")

      old
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -91, :day))
      |> Repo.update!()

      assert Notifications.prune_deliveries(DateTime.add(DateTime.utc_now(), -90, :day)) == 1
      assert [%Delivery{id: id}] = Repo.all(Delivery)
      assert id == recent.id
    end

    test "deleting a channel deletes its deliveries" do
      channel = channel_fixture()
      {:ok, _} = Notifications.enqueue_delivery(channel, "test", "test:1")

      {:ok, _} = Notifications.delete_channel(channel)
      assert Repo.aggregate(Delivery, :count) == 0
    end
  end
end
