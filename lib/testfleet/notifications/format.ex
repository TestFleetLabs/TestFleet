defmodule TestFleet.Notifications.Format do
  @moduledoc """
  Turns a `TestFleet.Notifications.Message` into what each kind of channel
  expects. Pure functions; `TestFleet.Notifications.Sender` sends the result.
  """

  alias TestFleet.Notifications.Message

  @webhook_version 1
  # Slack limits header blocks to 150 characters and a section to 10 fields.
  @slack_header_max 150
  @slack_fields_max 10

  ## Slack

  @doc "An incoming webhook body: a plain-text fallback and Block Kit blocks."
  def slack(%Message{} = message) do
    blocks =
      [
        %{
          "type" => "header",
          "text" => %{
            "type" => "plain_text",
            "text" => truncate(message.title, @slack_header_max)
          }
        },
        message.summary &&
          %{
            "type" => "section",
            "text" => %{"type" => "mrkdwn", "text" => slack_escape(message.summary)}
          },
        message.facts != [] &&
          %{
            "type" => "section",
            "fields" =>
              for {label, value} <- Enum.take(message.facts, @slack_fields_max) do
                %{
                  "type" => "mrkdwn",
                  "text" => "*#{slack_escape(label)}*\n#{slack_escape(value)}"
                }
              end
          },
        message.link &&
          %{
            "type" => "actions",
            "elements" => [
              %{
                "type" => "button",
                "text" => %{"type" => "plain_text", "text" => message.link.label},
                "url" => message.link.url
              }
            ]
          }
      ]
      |> Enum.filter(& &1)

    %{"text" => message.title, "blocks" => blocks}
  end

  # Slack's mrkdwn treats these three as control characters.
  defp slack_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  ## Teams

  @doc "A Teams Workflows webhook body: a message with one Adaptive Card (1.4)."
  def teams(%Message{} = message) do
    body =
      [
        %{
          "type" => "TextBlock",
          "text" => message.title,
          "weight" => "Bolder",
          "size" => "Medium",
          "wrap" => true
        },
        message.summary && %{"type" => "TextBlock", "text" => message.summary, "wrap" => true},
        message.facts != [] &&
          %{
            "type" => "FactSet",
            "facts" =>
              for({label, value} <- message.facts, do: %{"title" => label, "value" => value})
          }
      ]
      |> Enum.filter(& &1)

    card =
      %{
        "$schema" => "http://adaptivecards.io/schemas/adaptive-card.json",
        "type" => "AdaptiveCard",
        "version" => "1.4",
        "body" => body
      }
      |> put_if(message.link, "actions", fn link ->
        [%{"type" => "Action.OpenUrl", "title" => link.label, "url" => link.url}]
      end)

    %{
      "type" => "message",
      "attachments" => [
        %{"contentType" => "application/vnd.microsoft.card.adaptive", "content" => card}
      ]
    }
  end

  ## Webhook

  @doc """
  A generic webhook body: a versioned envelope plus the event's payload.
  `delivery_id` is `nil` for "Send test", which is not a stored delivery.
  """
  def webhook(%Message{} = message, delivery_id) do
    Map.merge(message.payload, %{
      "version" => @webhook_version,
      "event" => message.event,
      "delivery_id" => delivery_id,
      "occurred_at" => message.occurred_at && DateTime.to_iso8601(message.occurred_at)
    })
  end

  @doc """
  The webhook headers for `body` (the encoded JSON). With a signing secret, the
  receiver verifies `X-TestFleet-Signature` as the hex HMAC-SHA256 of
  `"<X-TestFleet-Timestamp>.<body>"`.
  """
  def webhook_headers(
        %Message{} = message,
        body,
        delivery_id,
        signing_secret,
        now \\ DateTime.utc_now()
      ) do
    headers =
      [{"x-testfleet-event", message.event}] ++
        if(delivery_id, do: [{"x-testfleet-delivery", to_string(delivery_id)}], else: [])

    case signing_secret do
      secret when secret in [nil, ""] ->
        headers

      secret ->
        timestamp = now |> DateTime.to_unix() |> to_string()

        headers ++
          [
            {"x-testfleet-timestamp", timestamp},
            {"x-testfleet-signature", "sha256=" <> sign(secret, timestamp, body)}
          ]
    end
  end

  @doc "The signature of a webhook body, as in `webhook_headers/5`."
  def sign(secret, timestamp, body) do
    :hmac
    |> :crypto.mac(:sha256, secret, [timestamp, ".", body])
    |> Base.encode16(case: :lower)
  end

  ## Email

  @doc "Subject, plain text, and HTML of an email."
  def email(%Message{} = message) do
    %{
      subject: "[TestFleet] " <> message.title,
      text: email_text(message),
      html: email_html(message)
    }
  end

  defp email_text(message) do
    [
      message.title,
      "",
      message.summary,
      message.summary && "",
      for({label, value} <- message.facts, do: "#{label}: #{value}"),
      message.link && ["", "#{message.link.label}: #{message.link.url}"]
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  defp email_html(message) do
    facts =
      for {label, value} <- message.facts do
        ~s(<tr><td style="padding:2px 16px 2px 0;color:#6b7280">#{escape(label)}</td>) <>
          ~s(<td style="padding:2px 0">#{escape(value)}</td></tr>)
      end

    """
    <div style="font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:14px;color:#111827">
      <p style="font-size:16px;font-weight:600;margin:0 0 8px">#{escape(message.title)}</p>
      #{if message.summary, do: ~s(<p style="margin:0 0 12px">#{escape(message.summary)}</p>)}
      #{if facts != [], do: ~s(<table style="border-collapse:collapse;margin:0 0 12px">#{facts}</table>)}
      #{if message.link, do: ~s(<p style="margin:0"><a href="#{escape(message.link.url)}">#{escape(message.link.label)}</a></p>)}
    </div>
    """
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  defp put_if(map, nil, _key, _fun), do: map
  defp put_if(map, value, key, fun), do: Map.put(map, key, fun.(value))

  defp truncate(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end
end
