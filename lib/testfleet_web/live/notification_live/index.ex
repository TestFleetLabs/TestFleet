defmodule TestFleetWeb.NotificationLive.Index do
  @moduledoc """
  Notification channels (Milestone 8, section 9), with "Send test", and the recent
  deliveries, live from the `notifications` topic.

  Webhook URLs and signing secrets never reach the browser: channels are redacted
  before they are streamed, and the stored ones are only loaded to send.
  """
  use TestFleetWeb, :live_view

  import TestFleetWeb.NotificationComponents

  alias TestFleet.Notifications
  alias TestFleet.Schedules.Timezones

  @recent_deliveries 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Notifications.subscribe_deliveries()

    channels = Enum.map(Notifications.list_channels(), &Notifications.redact/1)

    {:ok,
     socket
     |> assign(:page_title, gettext("Notifications"))
     |> assign(:timezone, Timezones.default())
     |> assign(:channel_count, length(channels))
     |> assign(:subscription_counts, Notifications.subscription_counts())
     |> assign(:email_unconfigured?, email_unconfigured?(channels))
     |> assign(:testing, MapSet.new())
     |> stream(:channels, channels)
     |> stream(:deliveries, Notifications.list_recent_deliveries(@recent_deliveries))}
  end

  @impl true
  def handle_info({:delivery, delivery}, socket),
    do: {:noreply, stream_insert(socket, :deliveries, delivery, at: 0, limit: @recent_deliveries)}

  defp email_unconfigured?(channels),
    do: not Notifications.email_configured?() and Enum.any?(channels, &(&1.kind == :email))

  @impl true
  def handle_event("send_test", %{"id" => id}, socket) do
    id = String.to_integer(id)
    channel = Notifications.get_channel!(id)

    {:noreply,
     socket
     |> update(:testing, &MapSet.put(&1, id))
     |> stream_insert(:channels, Notifications.redact(channel))
     |> start_async({:send_test, id}, fn -> {channel.name, Notifications.send_test(channel)} end)}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    channel = Notifications.get_channel!(id)
    {:ok, channel} = Notifications.set_channel_enabled(channel, not channel.enabled)

    message =
      if channel.enabled,
        do: gettext("%{name} is enabled.", name: channel.name),
        else: gettext("%{name} is disabled: it sends nothing until enabled.", name: channel.name)

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> stream_insert(:channels, Notifications.redact(channel))}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    channel = Notifications.get_channel!(id)
    {:ok, _} = Notifications.delete_channel(channel)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Channel %{name} deleted.", name: channel.name))
     |> update(:channel_count, &(&1 - 1))
     |> stream_delete(:channels, channel)}
  end

  @impl true
  def handle_async({:send_test, id}, result, socket) do
    socket =
      case result do
        {:ok, {name, :ok}} ->
          put_flash(socket, :info, gettext("Test notification sent to %{name}.", name: name))

        {:ok, {name, {:error, reason}}} ->
          put_flash(
            socket,
            :error,
            gettext("Test notification to %{name} failed: %{reason}", name: name, reason: reason)
          )

        {:exit, reason} ->
          put_flash(
            socket,
            :error,
            gettext("The test failed: %{reason}", reason: inspect(reason))
          )
      end

    socket = update(socket, :testing, &MapSet.delete(&1, id))

    # The channel may have been deleted meanwhile.
    case Notifications.get_channel(id) do
      nil -> {:noreply, socket}
      channel -> {:noreply, stream_insert(socket, :channels, Notifications.redact(channel))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:notifications}>
      <div id="notifications" class="space-y-8">
        <.page_header
          title={gettext("Notifications")}
          description={
            gettext("Where TestFleet reports failing and recovered suites, and its own problems.")
          }
        >
          <:actions>
            <.button id="new-channel" variant="primary" navigate={~p"/notifications/channels/new"}>
              <.icon name="hero-plus-mini" class="size-4" /> {gettext("New channel")}
            </.button>
          </:actions>
        </.page_header>

        <p
          :if={@email_unconfigured?}
          id="email-unconfigured"
          class="flex items-start gap-2 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
        >
          <.icon name="hero-exclamation-triangle-mini" class="mt-0.5 size-4 shrink-0 text-warning" />
          {gettext(
            "Email is not configured on this server, so email channels send nothing. Set SMTP_HOST and the other SMTP_ variables."
          )}
        </p>

        <.empty_state
          :if={@channel_count == 0}
          id="channels-empty"
          icon="hero-bell-slash"
          title={gettext("No channels yet")}
        >
          {gettext("Add an email list, a Slack or Teams channel, or a webhook to get notified.")}
        </.empty_state>

        <.panel :if={@channel_count > 0} id="channels" title={gettext("Channels")}>
          <div class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-base-300 text-xs font-medium tracking-wide text-base-content/60 uppercase">
                <tr>
                  <th class="px-5 py-3 font-medium">{gettext("Name")}</th>
                  <th class="px-5 py-3 font-medium">{gettext("Kind")}</th>
                  <th class="px-5 py-3 font-medium">{gettext("Sends to")}</th>
                  <th class="px-5 py-3"><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>
              <tbody id="channel-list" phx-update="stream" class="divide-y divide-base-300">
                <tr
                  :for={{id, channel} <- @streams.channels}
                  id={id}
                  class={[
                    "transition-colors duration-150 hover:bg-base-200/40",
                    !channel.enabled && "text-base-content/50"
                  ]}
                >
                  <td class="px-5 py-3">
                    <span class="font-medium">{channel.name}</span>
                    <.badge :if={!channel.enabled} id={"channel-#{channel.id}-disabled"} class="ml-2">
                      {gettext("disabled")}
                    </.badge>
                    <.link
                      id={"channel-#{channel.id}-subscriptions"}
                      navigate={~p"/notifications/channels/#{channel.id}/edit"}
                      class={[
                        "mt-0.5 block text-xs transition-colors hover:text-primary",
                        if(Map.get(@subscription_counts, channel.id, 0) == 0,
                          do: "text-warning",
                          else: "text-base-content/60"
                        )
                      ]}
                    >
                      {case Map.get(@subscription_counts, channel.id, 0) do
                        0 -> gettext("receives nothing yet")
                        count -> ngettext("1 subscription", "%{count} subscriptions", count)
                      end}
                    </.link>
                  </td>
                  <td class="px-5 py-3"><.channel_kind kind={channel.kind} /></td>
                  <td class="max-w-64 truncate px-5 py-3"><.channel_target channel={channel} /></td>
                  <td class="w-0 px-5 py-2">
                    <div class="flex items-center justify-end gap-1">
                      <.button
                        id={"test-channel-#{channel.id}"}
                        variant="ghost"
                        size="sm"
                        phx-click="send_test"
                        phx-value-id={channel.id}
                        disabled={MapSet.member?(@testing, channel.id)}
                        title={gettext("Send test")}
                        aria-label={gettext("Send a test to %{name}", name: channel.name)}
                      >
                        <.icon
                          name={
                            if MapSet.member?(@testing, channel.id),
                              do: "hero-arrow-path-mini",
                              else: "hero-paper-airplane-mini"
                          }
                          class={[
                            "size-4",
                            MapSet.member?(@testing, channel.id) && "motion-safe:animate-spin"
                          ]}
                        />
                      </.button>
                      <.button
                        id={"toggle-channel-#{channel.id}"}
                        variant="ghost"
                        size="sm"
                        phx-click="toggle"
                        phx-value-id={channel.id}
                        title={if channel.enabled, do: gettext("Disable"), else: gettext("Enable")}
                        aria-label={
                          if channel.enabled,
                            do: gettext("Disable %{name}", name: channel.name),
                            else: gettext("Enable %{name}", name: channel.name)
                        }
                      >
                        <.icon
                          name={if channel.enabled, do: "hero-pause-mini", else: "hero-play-mini"}
                          class="size-4"
                        />
                      </.button>
                      <.button
                        id={"edit-channel-#{channel.id}"}
                        variant="ghost"
                        size="sm"
                        navigate={~p"/notifications/channels/#{channel.id}/edit"}
                        aria-label={gettext("Edit %{name}", name: channel.name)}
                      >
                        <.icon name="hero-pencil-square-mini" class="size-4" />
                      </.button>
                      <.button
                        id={"delete-channel-#{channel.id}"}
                        variant="ghost"
                        size="sm"
                        phx-click="delete"
                        phx-value-id={channel.id}
                        data-confirm={
                          gettext("Delete %{name}? It stops receiving notifications.",
                            name: channel.name
                          )
                        }
                        aria-label={gettext("Delete %{name}", name: channel.name)}
                      >
                        <.icon name="hero-trash-mini" class="size-4" />
                      </.button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>

        <.panel id="deliveries" title={gettext("Recent deliveries")}>
          <ul id="delivery-list" phx-update="stream" class="divide-y divide-base-300">
            <li id="deliveries-empty" class="hidden only:block">
              <.empty_state
                id="deliveries-empty-state"
                icon="hero-paper-airplane"
                title={gettext("Nothing sent yet")}
                compact
              >
                {gettext("Notifications appear here when a suite fails, recovers, or cannot run.")}
              </.empty_state>
            </li>
            <li
              :for={{id, delivery} <- @streams.deliveries}
              id={id}
              class="flex flex-wrap items-center gap-x-4 gap-y-1 px-5 py-3 text-sm"
            >
              <span class="w-44 shrink-0 text-xs text-base-content/60">
                <.local_time at={delivery.inserted_at} timezone={@timezone} />
              </span>
              <span class="min-w-0 flex-1">
                <span class="font-medium">{event_label(delivery.event)}</span>
                <span class="text-base-content/60">→ {delivery.channel.name}</span>
                <.link
                  :if={delivery.run_id}
                  navigate={~p"/runs/#{delivery.run_id}"}
                  class="ml-1 font-mono text-xs text-base-content/60 hover:text-primary"
                >
                  #{delivery.run_id}
                </.link>
              </span>
              <span
                :if={delivery.last_error}
                class="max-w-72 truncate text-xs text-base-content/60"
                title={delivery.last_error}
              >
                {delivery.last_error}
              </span>
              <.delivery_status id={"delivery-#{delivery.id}-status"} delivery={delivery} />
            </li>
          </ul>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
