defmodule TestFleetWeb.NotificationLive.ChannelForm do
  @moduledoc """
  Creates and edits a notification channel, with "Send test".

  The URL and the signing secret never reach the browser: the form is built from a
  redacted channel, and the stored one is only loaded where it is needed, when
  saving or sending a test. What the user types is echoed back while editing (the
  browser has it anyway).

  An existing channel also has its subscriptions here: what it receives,
  from which projects and environments. A new channel opens here after saving.
  """
  use TestFleetWeb, :live_view

  import TestFleetWeb.NotificationComponents

  alias TestFleet.{Environments, Notifications, Projects}
  alias TestFleet.Notifications.{Channel, Subscription}
  alias TestFleet.Projects.Project

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
    channel =
      Notifications.get_channel!(socket.assigns.current_scope, id) |> Notifications.redact()

    subscriptions = Notifications.list_subscriptions(channel)

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: channel.name))
    |> assign(:channel, channel)
    |> assign_form(Notifications.change_channel(channel))
    |> assign(:projects, Projects.list_projects(socket.assigns.current_scope))
    |> assign(:subscription_count, length(subscriptions))
    |> stream(:subscriptions, subscriptions)
    |> assign_subscription_form(new_subscription(channel, %{}))
  end

  defp assign_form(socket, changeset, opts \\ []) do
    socket
    |> assign(:form, to_form(changeset, opts))
    |> assign(:kind, Ecto.Changeset.get_field(changeset, :kind))
  end

  defp new_subscription(channel, params) do
    params = Map.put_new(params, "events", Subscription.default_events())
    Notifications.change_subscription(%Subscription{channel_id: channel.id}, params)
  end

  # Only projects of the organization (the page's list); the id comes from the form.
  defp environments(projects, project_id) do
    case Enum.find(projects, &(&1.id == project_id)) do
      %Project{} = project -> Environments.list_environments(project)
      nil -> []
    end
  end

  defp assign_subscription_form(socket, changeset, opts \\ []) do
    project_id = Ecto.Changeset.get_field(changeset, :project_id)

    socket
    |> assign(:subscription_form, to_form(changeset, opts))
    |> assign(:subscription_events, Ecto.Changeset.get_field(changeset, :events) || [])
    |> assign(:subscription_project_id, project_id)
    |> assign(:environments, environments(socket.assigns.projects, project_id))
  end

  # Choosing another project drops an environment of the previous one, and a
  # project drops the system events it cannot have.
  defp normalize_subscription_params(params, socket) do
    project_id = params["project_id"]

    params =
      if project_id != to_string(socket.assigns.subscription_project_id || ""),
        do: Map.put(params, "environment_id", ""),
        else: params

    if project_id not in [nil, ""],
      do: Map.update(params, "events", [], &(&1 -- Subscription.system_events())),
      else: params
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
          Notifications.create_channel(socket.assigns.current_scope, params)

        %Channel{id: id} ->
          Notifications.get_channel!(socket.assigns.current_scope, id)
          |> Notifications.update_channel(params)
      end

    case {result, socket.assigns.channel.id} do
      # A new channel receives nothing yet: its page asks what it should.
      {{:ok, channel}, nil} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Channel %{name} saved. Now choose what it receives.", name: channel.name)
         )
         |> push_navigate(
           to: ~p"/#{socket.assigns.organization}/notifications/channels/#{channel.id}/edit"
         )}

      {{:ok, channel}, _id} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Channel %{name} saved.", name: channel.name))
         |> push_navigate(to: ~p"/#{socket.assigns.organization}/notifications")}

      {{:error, changeset}, _id} ->
        # A failed update was built from the stored channel; its secrets must not
        # reach the form.
        changeset = %{changeset | data: Notifications.redact(changeset.data)}
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("validate_subscription", %{"subscription" => params}, socket) do
    params = normalize_subscription_params(params, socket)
    changeset = new_subscription(socket.assigns.channel, params)
    {:noreply, assign_subscription_form(socket, changeset, action: :validate)}
  end

  def handle_event("add_subscription", %{"subscription" => params}, socket) do
    params = normalize_subscription_params(params, socket)

    case Notifications.create_subscription(socket.assigns.channel, params) do
      {:ok, subscription} ->
        subscription = TestFleet.Repo.preload(subscription, [:project, :environment])

        {:noreply,
         socket
         |> update(:subscription_count, &(&1 + 1))
         |> stream_insert(:subscriptions, subscription)
         |> assign_subscription_form(new_subscription(socket.assigns.channel, %{}))}

      {:error, changeset} ->
        {:noreply, assign_subscription_form(socket, changeset)}
    end
  end

  def handle_event("delete_subscription", %{"id" => id}, socket) do
    subscription = Notifications.get_subscription!(socket.assigns.channel, id)

    # Only this channel's subscriptions can be deleted from its page.
    if subscription.channel_id == socket.assigns.channel.id do
      {:ok, _} = Notifications.delete_subscription(subscription)

      {:noreply,
       socket
       |> update(:subscription_count, &(&1 - 1))
       |> stream_delete(:subscriptions, subscription)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("send_test", _params, socket) do
    params = socket.assigns.form.params
    channel_id = socket.assigns.channel.id
    scope = socket.assigns.current_scope

    {:noreply,
     socket
     |> assign(:test_result, :sending)
     |> start_async(:send_test, fn ->
       channel =
         if channel_id, do: Notifications.get_channel!(scope, channel_id), else: %Channel{}

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
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:notifications}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/#{@organization}/notifications"}>{gettext("Notifications")}</:crumb>

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
                /> {gettext(
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
            /> <.test_result result={@test_result} />
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
              <.button navigate={~p"/#{@organization}/notifications"}>{gettext("Cancel")}</.button>
              <.button id="save-channel" variant="primary" phx-disable-with={gettext("Saving...")}>
                {gettext("Save")}
              </.button>
            </:footer>
          </.form_card>
        </.form>

        <.panel
          :if={@channel.id}
          id="subscriptions"
          title={gettext("What it receives")}
          class="max-w-2xl"
        >
          <p
            :if={@subscription_count == 0}
            id="subscriptions-empty"
            class="flex items-start gap-2 border-b border-base-300 bg-warning/5 px-5 py-3 text-sm text-base-content/70"
          >
            <.icon name="hero-bell-slash-mini" class="mt-0.5 size-4 shrink-0 text-warning" /> {gettext(
              "Nothing yet: this channel receives no notifications until you add a subscription."
            )}
          </p>

          <ul id="subscription-list" phx-update="stream" class="divide-y divide-base-300">
            <li
              :for={{id, subscription} <- @streams.subscriptions}
              id={id}
              class="flex items-start justify-between gap-4 px-5 py-3"
            >
              <div class="min-w-0 space-y-1.5 text-sm">
                <p><.subscription_scope subscription={subscription} /></p>

                <p class="flex flex-wrap gap-1.5">
                  <.badge
                    :for={event <- subscription.events}
                    tone={if String.starts_with?(event, "system."), do: :warning, else: :neutral}
                  >
                    {event_label(event)}
                  </.badge>
                </p>
              </div>

              <.button
                id={"delete-subscription-#{subscription.id}"}
                variant="ghost"
                size="sm"
                phx-click="delete_subscription"
                phx-value-id={subscription.id}
                aria-label={gettext("Remove this subscription")}
              >
                <.icon name="hero-trash-mini" class="size-4" />
              </.button>
            </li>
          </ul>

          <.form
            for={@subscription_form}
            id="subscription-form"
            phx-change="validate_subscription"
            phx-submit="add_subscription"
            class="space-y-4 border-t border-base-300 bg-base-200/30 px-5 py-4"
          >
            <p class="text-sm font-semibold">{gettext("Add a subscription")}</p>

            <div class="grid gap-4 sm:grid-cols-2">
              <.input
                field={@subscription_form[:project_id]}
                type="select"
                label={gettext("Project")}
                prompt={gettext("All projects")}
                options={for project <- @projects, do: {project.name, project.id}}
              />
              <.input
                :if={@subscription_project_id}
                field={@subscription_form[:environment_id]}
                type="select"
                label={gettext("Environment")}
                prompt={gettext("All environments")}
                options={for environment <- @environments, do: {environment.name, environment.id}}
              />
            </div>

            <fieldset class="space-y-2">
              <%!-- An empty value, so that unchecking everything sends an empty list. --%>
              <input type="hidden" name="subscription[events][]" value="" />
              <legend class="mb-1 text-sm font-medium">{gettext("Run events")}</legend>

              <.event_checkbox
                :for={event <- Subscription.run_events()}
                event={event}
                checked={event in @subscription_events}
                disabled={false}
              />
            </fieldset>

            <fieldset class="space-y-2">
              <legend class="mb-1 text-sm font-medium">
                {gettext("System events")}
                <span :if={@subscription_project_id} class="font-normal text-base-content/60">
                  · {gettext("only for all projects")}
                </span>
              </legend>

              <.event_checkbox
                :for={event <- Subscription.system_events()}
                event={event}
                checked={event in @subscription_events}
                disabled={@subscription_project_id != nil}
              />
            </fieldset>

            <p
              :for={message <- Enum.map(@subscription_form[:events].errors, &translate_error/1)}
              id="subscription-events-error"
              class="text-sm text-error"
            >
              {message}
            </p>

            <div class="flex justify-end">
              <.button id="add-subscription" variant="primary" size="sm">
                <.icon name="hero-plus-mini" class="size-4" /> {gettext("Add")}
              </.button>
            </div>
          </.form>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :event, :string, required: true
  attr :checked, :boolean, required: true
  attr :disabled, :boolean, required: true

  defp event_checkbox(assigns) do
    ~H"""
    <label
      for={"subscription-event-#{String.replace(@event, ".", "-")}"}
      class={[
        "flex cursor-pointer items-start gap-2.5 text-sm",
        @disabled && "cursor-not-allowed opacity-50"
      ]}
    >
      <input
        type="checkbox"
        id={"subscription-event-#{String.replace(@event, ".", "-")}"}
        name="subscription[events][]"
        value={@event}
        checked={@checked and not @disabled}
        disabled={@disabled}
        class="mt-0.5 size-4 cursor-pointer rounded border-base-300 accent-primary"
      />
      <span>
        <span class="font-medium">{event_label(@event)}</span>
        <span class="block text-xs text-base-content/60">{event_description(@event)}</span>
      </span>
    </label>
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
