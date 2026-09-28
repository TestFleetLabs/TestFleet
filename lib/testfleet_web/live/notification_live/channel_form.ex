defmodule TestFleetWeb.NotificationLive.ChannelForm do
  @moduledoc """
  Creates and edits a notification channel, with "Send test" (Milestone 8,
  section 4).

  The URL and the signing secret never reach the browser: the form is built from a
  redacted channel, and the stored one is only loaded where it is needed, when
  saving or sending a test. What the user types is echoed back while editing (the
  browser has it anyway).
  """
  use TestFleetWeb, :live_view

  import TestFleetWeb.NotificationComponents

  alias TestFleet.Notifications
  alias TestFleet.Notifications.Channel

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:test_result, nil)
     |> assign(:email_configured?, Notifications.email_configured?())
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("New channel"))
    |> assign(:channel, %Channel{})
    |> assign_form(Notifications.change_channel(%Channel{}))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    channel = id |> Notifications.get_channel!() |> Notifications.redact()

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: channel.name))
    |> assign(:channel, channel)
    |> assign_form(Notifications.change_channel(channel))
  end

  defp assign_form(socket, changeset, opts \\ []) do
    socket
    |> assign(:form, to_form(changeset, opts))
    |> assign(:kind, Ecto.Changeset.get_field(changeset, :kind))
  end

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    changeset = Notifications.change_channel(socket.assigns.channel, params)

    {:noreply,
     socket
     |> assign_form(changeset, action: :validate)
     # The result belonged to the values before this change.
     |> assign(:test_result, nil)}
  end

  def handle_event("save", %{"channel" => params}, socket) do
    result =
      case socket.assigns.channel do
        %Channel{id: nil} ->
          Notifications.create_channel(params)

        %Channel{id: id} ->
          id |> Notifications.get_channel!() |> Notifications.update_channel(params)
      end

    case result do
      {:ok, channel} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Channel %{name} saved.", name: channel.name))
         |> push_navigate(to: ~p"/notifications")}

      {:error, changeset} ->
        # A failed update was built from the stored channel; its secrets must not
        # reach the form.
        changeset = %{changeset | data: Notifications.redact(changeset.data)}
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("send_test", _params, socket) do
    params = socket.assigns.form.params
    channel_id = socket.assigns.channel.id

    {:noreply,
     socket
     |> assign(:test_result, :sending)
     |> start_async(:send_test, fn ->
       channel = if channel_id, do: Notifications.get_channel!(channel_id), else: %Channel{}
       Notifications.send_test(channel, params)
     end)}
  end

  @impl true
  def handle_async(:send_test, {:ok, result}, socket),
    do: {:noreply, assign(socket, :test_result, result)}

  def handle_async(:send_test, {:exit, reason}, socket) do
    {:noreply,
     assign(
       socket,
       :test_result,
       {:error, gettext("The test failed: %{reason}", reason: inspect(reason))}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:notifications}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/notifications"}>{gettext("Notifications")}</:crumb>
            <:crumb>{if @channel.id, do: @channel.name, else: gettext("New channel")}</:crumb>
          </.breadcrumbs>
          <.page_header title={@page_title} />
        </div>

        <.form for={@form} id="channel-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="#e2e-alerts" />

            <.input
              :if={!@channel.id}
              field={@form[:kind]}
              type="select"
              label={gettext("Kind")}
              prompt={gettext("Choose where to send")}
              options={for kind <- Channel.kinds(), do: {kind_label(kind), kind}}
            />
            <div :if={@channel.id} id="channel-kind">
              <p class="mb-1.5 text-sm font-medium">{gettext("Kind")}</p>
              <.channel_kind kind={@channel.kind} />
            </div>

            <%= if @kind == :email do %>
              <.input
                field={@form[:recipients_text]}
                type="textarea"
                rows="3"
                label={gettext("Addresses")}
                placeholder="qa@company.com, oncall@company.com"
                spellcheck="false"
                hint={gettext("Up to 20, separated by commas or new lines. One email goes to all.")}
              />
              <p
                :if={!@email_configured?}
                id="email-unconfigured"
                class="flex items-start gap-2 rounded-lg bg-warning/10 px-3.5 py-3 text-sm"
              >
                <.icon
                  name="hero-exclamation-triangle-mini"
                  class="mt-0.5 size-4 shrink-0 text-warning"
                />
                {gettext(
                  "Email is not configured on this server: this channel can be saved, but sends nothing until SMTP_HOST is set."
                )}
              </p>
            <% end %>

            <.input
              :if={Channel.url_kind?(@kind)}
              field={@form[:url]}
              type="text"
              label={url_label(@kind)}
              placeholder={url_placeholder(@kind)}
              autocomplete="off"
              spellcheck="false"
              hint={url_hint(@kind, @channel)}
            />

            <%= if @kind == :webhook do %>
              <.input
                field={@form[:signing_secret]}
                type="password"
                label={gettext("Signing secret (optional)")}
                autocomplete="new-password"
                hint={
                  if @channel.signing_secret_set,
                    do: gettext("Leave empty to keep the current secret."),
                    else:
                      gettext(
                        "At least 16 characters. Each request then carries X-TestFleet-Signature: the HMAC-SHA256 of \"<X-TestFleet-Timestamp>.<body>\"."
                      )
                }
              />
              <.input
                :if={@channel.signing_secret_set}
                field={@form[:clear_signing_secret]}
                type="checkbox"
                label={gettext("Remove the signing secret")}
              />
            <% end %>

            <.input
              field={@form[:enabled]}
              type="checkbox"
              label={gettext("Enabled")}
              hint={gettext("A disabled channel keeps its settings but sends nothing.")}
            />

            <.test_result result={@test_result} />

            <:footer>
              <.button
                id="send-test"
                type="button"
                phx-click="send_test"
                disabled={@test_result == :sending}
                class="mr-auto"
              >
                <.icon name="hero-paper-airplane-mini" class="size-4" /> {gettext("Send test")}
              </.button>
              <.button navigate={~p"/notifications"}>{gettext("Cancel")}</.button>
              <.button id="save-channel" variant="primary" phx-disable-with={gettext("Saving...")}>
                {gettext("Save")}
              </.button>
            </:footer>
          </.form_card>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp url_label(:slack), do: gettext("Incoming webhook URL")
  defp url_label(:teams), do: gettext("Workflows webhook URL")
  defp url_label(:webhook), do: gettext("URL")

  defp url_placeholder(:slack), do: "https://hooks.slack.com/services/…"
  defp url_placeholder(:teams), do: "https://….logic.azure.com/workflows/…"
  defp url_placeholder(:webhook), do: "https://ci.company.com/hooks/testfleet"

  # The URL holds a token, so an existing one is only named by its host.
  defp url_hint(_kind, %Channel{id: id, url_hint: hint}) when id != nil and hint != nil,
    do: gettext("Leave empty to keep the current URL (%{hint}).", hint: hint)

  defp url_hint(:slack, _channel),
    do:
      gettext(
        "From a Slack app's Incoming Webhooks. It is stored encrypted and never shown again."
      )

  defp url_hint(:teams, _channel),
    do:
      gettext(
        "In Teams, add the workflow \"Post to a channel when a webhook request is received\" and copy its URL. It is stored encrypted and never shown again."
      )

  defp url_hint(:webhook, _channel),
    do:
      gettext(
        "TestFleet POSTs JSON to this URL for every event. It is stored encrypted and never shown again."
      )

  attr :result, :any, required: true

  defp test_result(%{result: nil} = assigns), do: ~H""

  defp test_result(assigns) do
    ~H"""
    <div
      id="test-result"
      role="status"
      class={[
        "flex items-start gap-2.5 rounded-lg px-3.5 py-3 text-sm transition-colors duration-200",
        case @result do
          :sending -> "bg-base-200 text-base-content/70"
          :ok -> "bg-success/10 text-success"
          {:error, _} -> "bg-error/10 text-error"
        end
      ]}
    >
      <%= case @result do %>
        <% :sending -> %>
          <.icon name="hero-arrow-path-mini" class="mt-0.5 size-4 shrink-0 motion-safe:animate-spin" />
          <span id="test-sending">{gettext("Sending a test notification...")}</span>
        <% :ok -> %>
          <.icon name="hero-check-circle-mini" class="mt-0.5 size-4 shrink-0" />
          <span id="test-ok">{gettext("Delivered.")}</span>
        <% {:error, message} -> %>
          <.icon name="hero-exclamation-circle-mini" class="mt-0.5 size-4 shrink-0" />
          <span id="test-error" class="wrap-break-word">{message}</span>
      <% end %>
    </div>
    """
  end
end
