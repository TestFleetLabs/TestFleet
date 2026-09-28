defmodule TestFleetWeb.NotificationComponents do
  @moduledoc """
  Pieces of the notification pages (Milestone 8, section 9). Channels passed here
  must be redacted (`TestFleet.Notifications.redact/1`).
  """
  use TestFleetWeb, :html

  @doc "The display name of a channel kind."
  def kind_label(:email), do: gettext("Email")
  def kind_label(:slack), do: gettext("Slack")
  def kind_label(:teams), do: gettext("Microsoft Teams")
  def kind_label(:webhook), do: gettext("Webhook")

  def kind_icon(:email), do: "hero-envelope"
  def kind_icon(:slack), do: "hero-hashtag"
  def kind_icon(:teams), do: "hero-user-group"
  def kind_icon(:webhook), do: "hero-bolt"

  @doc "Renders a channel's kind with its icon."
  attr :kind, :atom, required: true
  attr :id, :string, default: nil

  def channel_kind(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1.5 text-sm text-base-content/80">
      <span class="grid size-6 place-items-center rounded-md bg-base-200 text-base-content/60">
        <.icon name={kind_icon(@kind)} class="size-3.5" />
      </span>
      {kind_label(@kind)}
    </span>
    """
  end

  @doc """
  Renders where a channel sends to: its addresses, or the host of its URL. The URL
  itself is a credential and never shown.
  """
  attr :channel, :map, required: true

  def channel_target(%{channel: %{kind: :email}} = assigns) do
    ~H"""
    <span class="text-sm text-base-content/70" title={Enum.join(@channel.email_recipients, ", ")}>
      {List.first(@channel.email_recipients)}
      <span :if={length(@channel.email_recipients) > 1} class="text-base-content/50">
        {gettext("+ %{count} more", count: length(@channel.email_recipients) - 1)}
      </span>
    </span>
    """
  end

  def channel_target(assigns) do
    ~H"""
    <span class="font-mono text-xs text-base-content/70">{@channel.url_hint}</span>
    """
  end
end
