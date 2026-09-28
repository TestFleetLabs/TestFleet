defmodule TestFleet.NotificationsFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Notifications` context.

  Slack, Teams, and webhook requests go to the `Req.Test` stub named
  `TestFleet.Notifications` (see `config/test.exs`); stub it before sending.
  """

  @slack_url "https://hooks.slack.com/services/T000/B000/secret-token-123"

  def slack_url, do: @slack_url

  @doc "A Slack channel unless `kind:` says otherwise; URL kinds get a URL with a token."
  def channel_fixture(attrs \\ %{}) do
    attrs = Map.new(attrs)
    unique = System.unique_integer([:positive])

    defaults =
      case Map.get(attrs, :kind, :slack) do
        :email -> %{kind: :email, recipients_text: "qa@example.com"}
        :webhook -> %{kind: :webhook, url: "https://hooks.example.com/testfleet?token=abc123"}
        :teams -> %{kind: :teams, url: "https://example.logic.azure.com/workflows/abc/triggers"}
        :slack -> %{kind: :slack, url: @slack_url}
      end

    {:ok, channel} =
      defaults
      |> Map.put(:name, "Channel #{unique}")
      |> Map.merge(attrs)
      |> TestFleet.Notifications.create_channel()

    channel
  end
end
