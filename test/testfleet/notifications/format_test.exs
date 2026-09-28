defmodule TestFleet.Notifications.FormatTest do
  # Milestone 8, section 8: what each kind of channel receives.
  use ExUnit.Case, async: true

  alias TestFleet.Notifications.{Format, Message}

  @message %Message{
    event: "run.failing",
    title: "Customer Portal E2E is failing on production",
    summary: "3 of 48 tests failed <after> a deploy & more",
    facts: [{"Environment", "production"}, {"Trigger", "schedule"}],
    link: %{label: "Open run #1234", url: "https://testfleet.example.com/runs/1234"},
    payload: %{"run" => %{"id" => 1234}},
    occurred_at: ~U[2026-09-28 14:02:11Z]
  }

  describe "slack/1" do
    test "a fallback text, a header, the summary, the facts, and a button" do
      assert %{"text" => title, "blocks" => [header, summary, facts, actions]} =
               Format.slack(@message)

      assert title == @message.title
      assert header["text"]["text"] == @message.title
      # Slack's control characters are escaped.
      assert summary["text"]["text"] == "3 of 48 tests failed &lt;after&gt; a deploy &amp; more"
      assert [%{"text" => "*Environment*\nproduction"}, _] = facts["fields"]

      assert [%{"type" => "button", "url" => "https://testfleet.example.com/runs/1234"}] =
               actions["elements"]
    end

    test "without summary, facts, or link, only the header remains" do
      message = %Message{event: "test", title: String.duplicate("x", 200)}

      assert %{"blocks" => [%{"type" => "header", "text" => %{"text" => text}}]} =
               Format.slack(message)

      assert String.length(text) == 150
    end
  end

  test "teams/1 is a message with one Adaptive Card" do
    assert %{
             "type" => "message",
             "attachments" => [
               %{"contentType" => "application/vnd.microsoft.card.adaptive", "content" => card}
             ]
           } = Format.teams(@message)

    assert %{"type" => "AdaptiveCard", "version" => "1.4"} = card

    assert [%{"text" => title}, %{"text" => _summary}, %{"type" => "FactSet", "facts" => facts}] =
             card["body"]

    assert title == @message.title
    assert [%{"title" => "Environment", "value" => "production"}, _] = facts

    assert [%{"type" => "Action.OpenUrl", "url" => "https://testfleet.example.com/runs/1234"}] =
             card["actions"]
  end

  describe "webhook" do
    test "the body is a versioned envelope around the payload" do
      assert Format.webhook(@message, 81) == %{
               "version" => 1,
               "event" => "run.failing",
               "delivery_id" => 81,
               "occurred_at" => "2026-09-28T14:02:11Z",
               "run" => %{"id" => 1234}
             }
    end

    test "without a secret, the headers name the event and the delivery" do
      assert Format.webhook_headers(@message, "{}", 81, nil) == [
               {"x-testfleet-event", "run.failing"},
               {"x-testfleet-delivery", "81"}
             ]
    end

    test "with a secret, the receiver can verify the signature" do
      body = ~s({"event":"run.failing"})
      now = ~U[2026-09-28 14:02:11Z]

      headers =
        @message
        |> Format.webhook_headers(body, 81, "a-long-signing-secret", now)
        |> Map.new()

      timestamp = headers["x-testfleet-timestamp"]
      assert timestamp == "1790604131"

      # What a receiver does, independently of Format.sign/3.
      expected =
        :crypto.mac(:hmac, :sha256, "a-long-signing-secret", timestamp <> "." <> body)
        |> Base.encode16(case: :lower)

      assert headers["x-testfleet-signature"] == "sha256=" <> expected
    end
  end

  test "email/1 has a tagged subject, a text part, and an escaped HTML part" do
    assert %{subject: subject, text: text, html: html} = Format.email(@message)

    assert subject == "[TestFleet] Customer Portal E2E is failing on production"
    assert text =~ "Environment: production"
    assert text =~ "Open run #1234: https://testfleet.example.com/runs/1234"
    assert html =~ "&lt;after&gt; a deploy &amp; more"
    refute html =~ "<after>"
  end
end
