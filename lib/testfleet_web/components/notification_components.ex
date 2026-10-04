defmodule TestFleetWeb.NotificationComponents do
  @moduledoc """
  Pieces of the notification pages. Channels passed here
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

  @doc "The display name of an event."
  def event_label("run.failing"), do: gettext("Failing")
  def event_label("run.recovered"), do: gettext("Recovered")
  def event_label("run.error"), do: gettext("Could not run")
  def event_label("system.docker_unreachable"), do: gettext("Docker unreachable")
  def event_label("system.docker_recovered"), do: gettext("Docker recovered")
  def event_label("system.scheduling_stalled"), do: gettext("Scheduling stalled")
  def event_label("system.scheduling_recovered"), do: gettext("Scheduling recovered")
  def event_label("test"), do: gettext("Test")
  def event_label(event), do: event

  @doc "When an event is sent."
  def event_description("run.failing"),
    do: gettext("A suite fails or times out after it passed. Not again while it stays red.")

  def event_description("run.recovered"), do: gettext("A failing suite passes again.")

  def event_description("run.error"),
    do: gettext("A run cannot execute (registry, image, Docker). Once, not for every repeat.")

  def event_description("system.docker_unreachable"),
    do: gettext("TestFleet cannot reach Docker for 5 minutes.")

  def event_description("system.docker_recovered"),
    do: gettext("Docker answers again, after that alert.")

  def event_description("system.scheduling_stalled"),
    do: gettext("Schedules are more than 10 minutes overdue.")

  def event_description("system.scheduling_recovered"),
    do: gettext("Schedules run again, after that alert.")

  @doc "Renders a subscription's scope: all projects, a project, or its environment."
  attr :subscription, :map, required: true

  def subscription_scope(%{subscription: %{project: nil}} = assigns) do
    ~H"""
    <span class="font-medium">{gettext("All projects")}</span>
    """
  end

  def subscription_scope(assigns) do
    ~H"""
    <span class="font-medium">{@subscription.project.name}</span>
    <span :if={@subscription.environment} class="text-base-content/60">
      · {@subscription.environment.name}
    </span>
    <span :if={!@subscription.environment} class="text-base-content/60">
      · {gettext("all environments")}
    </span>
    """
  end

  @doc "Renders a delivery's status, with the reason of a failure as its title."
  attr :delivery, :map, required: true
  attr :id, :string, default: nil

  def delivery_status(assigns) do
    ~H"""
    <span
      id={@id}
      title={@delivery.last_error}
      class={[
        "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium",
        case @delivery.status do
          :sent -> "bg-success/10 text-success"
          :failed -> "bg-error/10 text-error"
          :pending -> "bg-base-200 text-base-content/70"
        end
      ]}
    >
      <.icon
        name={
          case @delivery.status do
            :sent -> "hero-check-mini"
            :failed -> "hero-x-mark-mini"
            :pending -> "hero-clock-mini"
          end
        }
        class="size-3.5"
      />
      {case @delivery.status do
        :sent -> gettext("sent")
        :failed -> gettext("failed")
        :pending -> if(@delivery.attempts > 0, do: gettext("retrying"), else: gettext("pending"))
      end}
    </span>
    """
  end

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
