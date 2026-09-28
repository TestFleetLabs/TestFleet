defmodule TestFleet.Notifications.DeliveryWorkerTest do
  # Milestone 8, section 8: attempts, retries, and what a delivery records.
  use TestFleet.DataCase, async: true

  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Delivery, DeliveryWorker}

  @moduletag :capture_log

  defp delivery(channel, event \\ "test") do
    {:ok, delivery} =
      Notifications.enqueue_delivery(channel, event, "#{event}:#{System.unique_integer()}")

    delivery
  end

  defp perform(delivery, attempt \\ 1),
    do: perform_job(DeliveryWorker, %{delivery_id: delivery.id}, attempt: attempt)

  defp reload(delivery), do: Repo.get!(Delivery, delivery.id)

  defp stub_status(status),
    do: Req.Test.stub(TestFleet.Notifications, &Plug.Conn.send_resp(&1, status, ""))

  test "a delivered notification is sent" do
    stub_status(200)
    delivery = channel_fixture() |> delivery()

    assert :ok = perform(delivery)

    assert %Delivery{status: :sent, attempts: 1, sent_at: %DateTime{}, last_error: nil} =
             reload(delivery)
  end

  test "a retryable failure stays pending until the last attempt" do
    stub_status(503)
    delivery = channel_fixture() |> delivery()

    assert {:error, "HTTP 503"} = perform(delivery, 1)
    assert %Delivery{status: :pending, attempts: 1, last_error: "HTTP 503"} = reload(delivery)

    assert {:error, "HTTP 503"} = perform(delivery, 5)
    assert %Delivery{status: :failed, attempts: 5} = reload(delivery)
  end

  test "a permanent failure ends the delivery at once" do
    stub_status(410)
    delivery = channel_fixture() |> delivery()

    assert {:cancel, "HTTP 410"} = perform(delivery)
    assert %Delivery{status: :failed, last_error: "HTTP 410"} = reload(delivery)
  end

  test "a disabled channel sends nothing" do
    channel = channel_fixture()
    delivery = delivery(channel)
    {:ok, _} = Notifications.set_channel_enabled(channel, false)

    assert {:cancel, "the channel is disabled"} = perform(delivery)
    assert %Delivery{status: :failed} = reload(delivery)
  end

  test "an event this version cannot render fails" do
    delivery = channel_fixture() |> delivery("run.unknown")

    assert {:cancel, "unknown event run.unknown"} = perform(delivery)
  end

  test "a delivery that is no longer pending is not sent again" do
    stub_status(200)
    delivery = channel_fixture() |> delivery()
    :ok = perform(delivery)

    Req.Test.stub(TestFleet.Notifications, fn _conn -> flunk("sent twice") end)
    assert :ok = perform(delivery, 2)
  end

  test "a deleted delivery is cancelled" do
    channel = channel_fixture()
    delivery = delivery(channel)
    {:ok, _} = Notifications.delete_channel(channel)

    assert {:cancel, _} = perform(delivery)
  end
end
