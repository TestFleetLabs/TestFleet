defmodule TestFleet.MultiOrganizationTest do
  # What changes in :multi mode. Not async: it switches the mode for the application.
  use TestFleet.DataCase, async: false

  import TestFleet.AccountsFixtures
  import TestFleet.NotificationsFixtures
  import TestFleet.RunsFixtures

  alias TestFleet.Accounts.Scope
  alias TestFleet.{Notifications, Runs}

  setup do
    previous = Application.get_env(:testfleet, :organizations)
    on_exit(fn -> Application.put_env(:testfleet, :organizations, previous) end)
    :ok
  end

  defp multi!, do: Application.put_env(:testfleet, :organizations, :multi)

  test "runs always pull, so a cached private image is never reused across organizations" do
    run = run_fixture()
    assert Runs.build_request(run).pull_policy == :auto

    multi!()
    assert Runs.build_request(run).pull_policy == :always
  end

  test "system events are not delivered to organizations" do
    channel = channel_fixture()

    {:ok, _} =
      Notifications.create_subscription(channel, %{events: ["system.docker_unreachable"]})

    multi!()
    assert {:ok, []} = Notifications.notify_system("system.docker_unreachable", "episode-1", %{})
  end

  test "a scope carries no organization until one is chosen" do
    user = user_fixture()

    multi!()
    assert %Scope{organization: nil, membership: nil} = Scope.for_user(user)
    assert_raise ArgumentError, fn -> TestFleet.Organizations.single() end
  end
end
