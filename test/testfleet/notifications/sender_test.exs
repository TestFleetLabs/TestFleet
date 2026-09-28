defmodule TestFleet.Notifications.SenderTest do
  # Milestone 8, section 8: sending, and which failures are worth retrying.
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias TestFleet.Notifications.{Channel, Message, Sender}

  @message %Message{
    event: "test",
    title: "Test notification from TestFleet",
    occurred_at: ~U[2026-09-28 14:02:11Z]
  }

  defp channel(kind, attrs \\ []) do
    struct!(
      %Channel{
        id: 1,
        name: "Alerts",
        kind: kind,
        url: "https://hooks.example.com/t/secret-token"
      },
      attrs
    )
  end

  defp stub(fun), do: Req.Test.stub(TestFleet.Notifications, fun)

  defp capture_request do
    test = self()

    stub(fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:request, conn, body})
      Req.Test.text(conn, "ok")
    end)
  end

  describe "URL channels" do
    test "Slack gets its blocks as JSON" do
      capture_request()
      assert :ok = Sender.deliver(channel(:slack), @message)

      assert_received {:request, conn, body}
      assert conn.method == "POST"
      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert %{"text" => "Test notification from TestFleet", "blocks" => _} = Jason.decode!(body)
    end

    test "Teams gets an Adaptive Card" do
      capture_request()
      assert :ok = Sender.deliver(channel(:teams), @message)

      assert_received {:request, _conn, body}
      assert %{"type" => "message", "attachments" => [_]} = Jason.decode!(body)
    end

    test "a webhook is signed over the exact body sent" do
      capture_request()

      assert :ok =
               Sender.deliver(
                 channel(:webhook, signing_secret: "a-long-signing-secret"),
                 @message,
                 delivery_id: 81
               )

      assert_received {:request, conn, body}
      assert %{"event" => "test", "delivery_id" => 81, "version" => 1} = Jason.decode!(body)
      assert ["81"] = Plug.Conn.get_req_header(conn, "x-testfleet-delivery")
      [timestamp] = Plug.Conn.get_req_header(conn, "x-testfleet-timestamp")
      [signature] = Plug.Conn.get_req_header(conn, "x-testfleet-signature")

      assert signature ==
               "sha256=" <>
                 (:crypto.mac(:hmac, :sha256, "a-long-signing-secret", timestamp <> "." <> body)
                  |> Base.encode16(case: :lower))
    end

    test "2xx is sent" do
      stub(&Plug.Conn.send_resp(&1, 204, ""))
      assert :ok = Sender.deliver(channel(:webhook), @message)
    end

    test "429 and 5xx are retried" do
      for status <- [429, 500, 503] do
        stub(&Plug.Conn.send_resp(&1, status, "busy"))
        assert {:error, :retry, "HTTP #{status}"} == Sender.deliver(channel(:slack), @message)
      end
    end

    test "other 4xx are permanent, and the response body is not kept" do
      for status <- [400, 403, 404, 410] do
        stub(&Plug.Conn.send_resp(&1, status, "channel_is_archived secret-token"))
        assert {:error, :permanent, "HTTP #{status}"} == Sender.deliver(channel(:slack), @message)
      end
    end

    test "redirects are not followed" do
      test = self()

      stub(fn conn ->
        send(test, :requested)

        conn
        |> Plug.Conn.put_resp_header("location", "http://169.254.169.254/latest")
        |> Plug.Conn.send_resp(302, "")
      end)

      assert {:error, :permanent, "HTTP 302: redirects are not followed"} =
               Sender.deliver(channel(:webhook), @message)

      assert_received :requested
      refute_received :requested
    end

    test "transport errors are retried, and their reason does not name the URL" do
      stub(&Req.Test.transport_error(&1, :econnrefused))

      assert {:error, :retry, reason} = Sender.deliver(channel(:webhook), @message)
      refute reason =~ "hooks.example.com"
      refute reason =~ "secret-token"
    end
  end

  test "email goes to all recipients in one message" do
    channel = channel(:email, url: nil, email_recipients: ["qa@example.com", "dev@example.com"])

    assert :ok = Sender.deliver(channel, @message)

    assert_email_sent(fn email ->
      assert email.subject == "[TestFleet] Test notification from TestFleet"
      assert email.to == [{"", "qa@example.com"}, {"", "dev@example.com"}]
      assert email.text_body =~ "Test notification from TestFleet"
    end)
  end
end
