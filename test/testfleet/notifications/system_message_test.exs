defmodule TestFleet.Notifications.SystemMessageTest do
  # Milestone 8, section 8: what system events say.
  use TestFleet.DataCase, async: true

  import TestFleet.NotificationsFixtures

  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Delivery, DeliveryWorker, Message}

  @at ~U[2026-09-28 14:10:00Z]

  test "Docker unreachable names the time, in the default time zone, and the error" do
    message =
      Message.system_event(
        "system.docker_unreachable",
        %{"since" => "2026-09-28T12:02:00Z", "message" => "connection refused"},
        @at
      )

    assert message.title == "Docker is not reachable"
    # config :testfleet, :default_timezone is Europe/Vienna: UTC+2 in September.
    assert message.summary =~ "since 2026-09-28 14:02 CEST"
    assert message.facts == [{"Error", "connection refused"}]

    assert message.payload == %{
             "system" => %{"since" => "2026-09-28T12:02:00Z", "message" => "connection refused"}
           }
  end

  test "Docker recovered names the outage" do
    message =
      Message.system_event(
        "system.docker_recovered",
        %{"since" => "2026-09-28T12:02:00Z", "recovered_at" => "2026-09-28T12:20:00Z"},
        @at
      )

    assert message.title == "Docker is reachable again"
    assert message.summary =~ "from 2026-09-28 14:02 CEST to 2026-09-28 14:20 CEST"
  end

  test "scheduling stalled lists the schedules and counts the rest" do
    message =
      Message.system_event(
        "system.scheduling_stalled",
        %{
          "count" => 12,
          "schedules" => ["A on prod (P)", "B on prod (P)"],
          "oldest_due" => "2026-09-28T11:30:00Z"
        },
        @at
      )

    assert message.title == "Scheduling is stalled"
    assert message.summary =~ "12 schedules are more than 10 minutes overdue"
    assert {"Overdue", "A on prod (P), B on prod (P) and 10 more"} in message.facts
  end

  test "scheduling recovered" do
    message =
      Message.system_event(
        "system.scheduling_recovered",
        %{"since" => "2026-09-28T12:00:00Z"},
        @at
      )

    assert message.title == "Scheduling runs again"
  end

  test "a system delivery is sent with its stored data" do
    test = self()

    Req.Test.stub(TestFleet.Notifications, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:body, Jason.decode!(body)})
      Req.Test.text(conn, "ok")
    end)

    channel = channel_fixture(kind: :webhook)

    {:ok, _} =
      Notifications.create_subscription(channel, %{"events" => ["system.docker_unreachable"]})

    {:ok, [delivery]} =
      Notifications.notify_system("system.docker_unreachable", "system.docker_unreachable:1", %{
        "since" => "2026-09-28T12:02:00Z",
        "message" => "down"
      })

    assert :ok = perform_job(DeliveryWorker, %{delivery_id: delivery.id})
    assert %Delivery{status: :sent, run_id: nil} = Repo.get!(Delivery, delivery.id)

    assert_received {:body,
                     %{
                       "event" => "system.docker_unreachable",
                       "system" => %{"message" => "down"}
                     }}

    # The same episode is not delivered twice.
    assert {:ok, []} =
             Notifications.notify_system(
               "system.docker_unreachable",
               "system.docker_unreachable:1",
               %{}
             )
  end
end
