defmodule TestFleet.Notifications.DestinationTest do
  # Changes the application environment.
  use ExUnit.Case, async: false

  alias TestFleet.Notifications.{Channel, Destination, Message, Sender}

  defp allow_private_hosts(value) do
    config = Application.get_env(:testfleet, TestFleet.Notifications, [])
    on_exit(fn -> Application.put_env(:testfleet, TestFleet.Notifications, config) end)

    Application.put_env(
      :testfleet,
      TestFleet.Notifications,
      Keyword.put(config, :allow_private_hosts, value)
    )
  end

  describe "internal?/1" do
    test "loopback, private, link-local, and reserved IPv4 addresses" do
      for address <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {172, 31, 255, 255},
            {192, 168, 1, 1},
            {169, 254, 169, 254},
            {100, 64, 0, 1},
            {0, 0, 0, 0},
            {224, 0, 0, 1}
          ] do
        assert Destination.internal?(address), inspect(address)
      end
    end

    test "public IPv4 addresses" do
      for address <- [{8, 8, 8, 8}, {172, 32, 0, 1}, {100, 128, 0, 1}, {192, 169, 0, 1}] do
        refute Destination.internal?(address), inspect(address)
      end
    end

    test "IPv6, including IPv4-mapped addresses" do
      assert Destination.internal?({0, 0, 0, 0, 0, 0, 0, 1})
      assert Destination.internal?({0xFC00, 0, 0, 0, 0, 0, 0, 1})
      assert Destination.internal?({0xFD12, 0, 0, 0, 0, 0, 0, 1})
      assert Destination.internal?({0xFE80, 0, 0, 0, 0, 0, 0, 1})
      assert Destination.internal?({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1})
      assert Destination.internal?({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 1})

      refute Destination.internal?({0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111})
      refute Destination.internal?({0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808})
    end
  end

  describe "check/1" do
    test "allows everything by default in :single mode" do
      assert :ok = Destination.check("http://127.0.0.1:2375/containers/x/kill")
    end

    test "refuses internal addresses when they are not allowed" do
      allow_private_hosts(false)

      assert {:error, "the host is on an internal network" <> _} =
               Destination.check("http://127.0.0.1:2375/containers/x/kill")

      assert {:error, _} = Destination.check("http://[::1]/hook")
      assert {:error, _} = Destination.check("http://localhost/hook")
      assert :ok = Destination.check("https://8.8.8.8/hook")
    end

    test "the sender does not send to a refused host" do
      allow_private_hosts(false)

      Req.Test.stub(TestFleet.Notifications, fn _conn -> flunk("the request was sent") end)

      channel = %Channel{id: 1, name: "Alerts", kind: :webhook, url: "http://10.0.0.5/secret"}
      message = %Message{event: "test", title: "Test", occurred_at: ~U[2026-09-28 14:02:11Z]}

      assert {:error, :permanent, reason} = Sender.deliver(channel, message)
      assert reason =~ "internal network"
      refute reason =~ "10.0.0.5"
    end
  end
end
