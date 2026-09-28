defmodule TestFleet.Notifications.WatchdogTest do
  # Milestone 8, section 7: alerts about Docker and scheduling, once per episode.
  #
  # Not async: the watchdog is its own process and reads the database through the
  # shared sandbox.
  use TestFleet.DataCase, async: false

  import TestFleet.NotificationsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Delivery, Watchdog}

  @moduletag :capture_log

  @t0 ~U[2026-09-28 14:00:00Z]

  setup do
    channel = channel_fixture()

    {:ok, _} =
      Notifications.create_subscription(channel, %{
        "events" => TestFleet.Notifications.Subscription.system_events()
      })

    clock = start_supervised!({Agent, fn -> @t0 end}, id: :clock)

    docker =
      start_supervised!(
        {Agent, fn -> %{reachable: true, since: nil, message: nil} end},
        id: :docker
      )

    start_supervised!(
      {Watchdog,
       enabled: true,
       interval: :timer.hours(1),
       now: fn -> Agent.get(clock, & &1) end,
       docker_status: fn -> Agent.get(docker, & &1) end}
    )

    %{channel: channel, clock: clock, docker: docker}
  end

  defp at(context, minutes) do
    Agent.update(context.clock, fn _ -> DateTime.add(@t0, minutes, :minute) end)
    :ok = Watchdog.check()
  end

  defp docker(context, status), do: Agent.update(context.docker, fn _ -> status end)

  defp events do
    Repo.all(from d in Delivery, order_by: d.id, select: {d.event, d.data})
  end

  describe "Docker" do
    test "alerts after 5 minutes, once, and reports the recovery", context do
      docker(context, %{reachable: false, since: @t0, message: "connection refused"})

      at(context, 4)
      assert events() == []

      at(context, 5)

      assert [
               {"system.docker_unreachable",
                %{"since" => since, "message" => "connection refused"}}
             ] =
               events()

      assert since == "2026-09-28T14:00:00Z"

      at(context, 6)
      assert length(events()) == 1

      docker(context, %{reachable: true, since: DateTime.add(@t0, 7, :minute), message: nil})
      at(context, 7)

      assert [_, {"system.docker_recovered", %{"since" => ^since, "recovered_at" => _}}] =
               events()

      at(context, 8)
      assert length(events()) == 2
    end

    test "a short outage stays quiet", context do
      docker(context, %{reachable: false, since: @t0, message: "proxy restarting"})
      at(context, 1)
      docker(context, %{reachable: true, since: DateTime.add(@t0, 2, :minute), message: nil})
      at(context, 2)

      assert events() == []
    end

    test "an outage that ended and began again between checks is two episodes", context do
      docker(context, %{reachable: false, since: @t0, message: "down"})
      at(context, 5)

      # Back and gone again within the minute: the first outage is over.
      again = DateTime.add(@t0, 6, :minute)
      docker(context, %{reachable: false, since: again, message: "down again"})
      at(context, 6)

      assert [{"system.docker_unreachable", _}, {"system.docker_recovered", _}] = events()

      at(context, 11)

      assert [_, _, {"system.docker_unreachable", %{"message" => "down again"}}] = events()
    end
  end

  describe "scheduling" do
    defp overdue_schedule(minutes_late, attrs \\ []) do
      [now: @t0]
      |> Keyword.merge(attrs)
      |> schedule_fixture()
      |> Ecto.Changeset.change(next_run_at: DateTime.add(@t0, -minutes_late, :minute))
      |> Repo.update!()
    end

    test "alerts on schedules more than 10 minutes overdue, once, and on the recovery",
         context do
      project = project_fixture(name: "Portal")
      test_definition = test_definition_fixture(project: project, name: "Checkout")
      schedule = overdue_schedule(5, project: project, test_definition: test_definition)

      at(context, 0)
      assert events() == []

      at(context, 6)

      assert [{"system.scheduling_stalled", %{"count" => 1, "schedules" => [name]}}] = events()
      assert name =~ "Checkout on "
      assert name =~ "(Portal)"

      at(context, 7)
      assert length(events()) == 1

      # The tick works again: the schedule moved on.
      schedule
      |> Ecto.Changeset.change(next_run_at: DateTime.add(@t0, 1, :day))
      |> Repo.update!()

      at(context, 8)
      assert [_, {"system.scheduling_recovered", %{"since" => _}}] = events()
    end

    test "many overdue schedules are one message, naming ten", context do
      project = project_fixture()
      for _ <- 1..12, do: overdue_schedule(30, project: project)

      at(context, 0)

      assert [{"system.scheduling_stalled", %{"count" => 12, "schedules" => names}}] = events()
      assert length(names) == 10
    end

    test "disabled schedules, and schedules of disabled test definitions, do not count",
         context do
      overdue_schedule(30) |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

      project = project_fixture()
      disabled = test_definition_fixture(project: project)
      overdue_schedule(30, project: project, test_definition: disabled)
      disabled |> Ecto.Changeset.change(enabled: false) |> Repo.update!()

      at(context, 0)
      assert events() == []
    end
  end

  test "a channel without system subscriptions gets nothing", context do
    other = channel_fixture()
    {:ok, _} = Notifications.create_subscription(other, %{"events" => ["run.failing"]})

    docker(context, %{reachable: false, since: @t0, message: "down"})
    at(context, 5)

    assert [%Delivery{channel_id: channel_id}] = Repo.all(Delivery)
    assert channel_id == context.channel.id
  end
end
