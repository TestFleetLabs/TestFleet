defmodule TestFleet.Notifications.HeartbeatTest do
  # The dead man's switch ping.
  #
  # Not async: it sets the heartbeat URL for the whole application.
  use TestFleet.DataCase, async: false

  import ExUnit.CaptureLog

  alias TestFleet.Notifications.Heartbeat
  alias TestFleet.Schedules.TickWorker

  @url "https://hc-ping.example.com/0f6b-secret-uuid"

  setup do
    previous = Application.fetch_env!(:testfleet, Heartbeat)
    Application.put_env(:testfleet, Heartbeat, Keyword.put(previous, :url, @url))
    on_exit(fn -> Application.put_env(:testfleet, Heartbeat, previous) end)
    on_exit(fn -> :persistent_term.erase({Heartbeat, :failing}) end)
  end

  defp stub(fun), do: Req.Test.stub(Heartbeat, fun)

  test "a completed tick pings the URL" do
    test = self()

    stub(fn conn ->
      send(test, {:ping, conn.method, conn.host, conn.request_path})
      Req.Test.text(conn, "OK")
    end)

    assert :ok = perform_job(TickWorker, %{})
    assert_receive {:ping, "GET", "hc-ping.example.com", "/0f6b-secret-uuid"}
  end

  test "without a URL, nothing is sent" do
    Application.put_env(:testfleet, Heartbeat, url: nil)
    stub(fn _conn -> flunk("pinged without a URL") end)

    assert Heartbeat.ping() == :disabled
  end

  test "failures are logged once per streak, without the URL" do
    stub(&Plug.Conn.send_resp(&1, 503, ""))

    log =
      capture_log(fn ->
        assert {:error, "HTTP 503"} = Heartbeat.ping()
        assert {:error, "HTTP 503"} = Heartbeat.ping()
      end)

    assert length(String.split(log, "heartbeat ping failed")) == 2
    refute log =~ "secret-uuid"

    # A success ends the streak, so the next failure is logged again.
    stub(&Req.Test.text(&1, "OK"))
    assert :ok = Heartbeat.ping()

    stub(&Req.Test.transport_error(&1, :econnrefused))
    assert capture_log(fn -> Heartbeat.ping() end) =~ "heartbeat ping failed"
  end
end
