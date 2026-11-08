defmodule TestFleet.UpdateCheckTest do
  # The check for a newer TestFleet release.
  #
  # Not async: the newer release is kept in :persistent_term for the whole
  # application, and the stub is shared with the check's process.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias TestFleet.UpdateCheck

  setup :set_req_test_to_shared

  setup do
    on_exit(fn -> :persistent_term.erase({UpdateCheck, :available}) end)
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp start(current_version) do
    start_supervised!(
      {UpdateCheck, enabled: true, name: :update_check_test, current_version: current_version}
    )

    :update_check_test
  end

  defp release(tag) do
    Req.Test.stub(UpdateCheck, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => tag,
        "html_url" => "https://github.com/testfleetlabs/testfleet/releases/tag/#{tag}"
      })
    end)
  end

  test "a newer release is available, with its page" do
    test = self()

    Req.Test.stub(UpdateCheck, fn conn ->
      send(
        test,
        {:request, conn.host, conn.request_path, Plug.Conn.get_req_header(conn, "user-agent")}
      )

      Req.Test.json(conn, %{
        "tag_name" => "v0.5.0",
        "html_url" => "https://github.com/testfleetlabs/testfleet/releases/tag/v0.5.0"
      })
    end)

    server = start("0.4.0")

    assert UpdateCheck.check(server) == %{
             version: "0.5.0",
             url: "https://github.com/testfleetlabs/testfleet/releases/tag/v0.5.0"
           }

    assert UpdateCheck.available().version == "0.5.0"

    assert_receive {:request, "api.github.com", "/repos/testfleetlabs/testfleet/releases/latest",
                    ["TestFleet/0.4.0"]}
  end

  test "the installed release, or an older one, is not an update" do
    release("v0.4.0")
    server = start("0.4.0")
    assert UpdateCheck.check(server) == nil

    release("v0.3.2")
    assert UpdateCheck.check(server) == nil
  end

  test "a prerelease of the latest release is older than it" do
    release("v0.5.0")
    assert %{version: "0.5.0"} = UpdateCheck.check(start("0.5.0-rc.1"))
  end

  test "an update installed since the last check is no longer shown" do
    release("v0.5.0")
    assert %{version: "0.5.0"} = UpdateCheck.check(start("0.4.0"))
    stop_supervised!(UpdateCheck)

    assert UpdateCheck.check(start("0.5.0")) == nil
    assert UpdateCheck.available() == nil
  end

  test "a tag that is not a version is ignored" do
    release("nightly")
    assert UpdateCheck.check(start("0.4.0")) == nil
  end

  test "no release published yet is not an error" do
    Req.Test.stub(UpdateCheck, &Plug.Conn.send_resp(&1, 404, ~s({"message": "Not Found"})))
    server = start("0.4.0")

    refute capture_log(fn -> assert UpdateCheck.check(server) == nil end) =~ "failed"
  end

  test "a failed check keeps what the last one found and logs once" do
    release("v0.5.0")
    server = start("0.4.0")
    assert %{version: "0.5.0"} = UpdateCheck.check(server)

    Req.Test.stub(UpdateCheck, &Req.Test.transport_error(&1, :econnrefused))

    log =
      capture_log(fn ->
        assert %{version: "0.5.0"} = UpdateCheck.check(server)
        assert %{version: "0.5.0"} = UpdateCheck.check(server)
      end)

    assert length(String.split(log, "update check failed")) == 2

    Req.Test.stub(UpdateCheck, &Plug.Conn.send_resp(&1, 403, "rate limited"))

    refute capture_log(fn -> UpdateCheck.check(server) end) =~ "update check failed"
  end

  test "disabled, it does not start" do
    assert UpdateCheck.start_link(enabled: false) == :ignore
  end
end
