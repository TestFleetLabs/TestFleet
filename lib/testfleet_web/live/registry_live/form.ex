defmodule TestFleetWeb.RegistryLive.Form do
  @moduledoc """
  Creates and edits registry credentials, with "Test connection".

  The password never reaches the browser: the form is built from a redacted
  registry, and the stored password is only loaded where it is needed, when
  saving or testing.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Registries
  alias TestFleet.Registries.Registry

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:connection, nil)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, gettext("New registry"))
    |> assign(:registry, %Registry{})
    |> assign(:form, to_form(Registries.change_registry(%Registry{})))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    registry = id |> Registries.get_registry!() |> Registries.redact()

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: registry.name))
    |> assign(:registry, registry)
    |> assign(:form, to_form(Registries.change_registry(registry)))
  end

  @impl true
  def handle_event("validate", %{"registry" => params}, socket) do
    changeset = Registries.change_registry(socket.assigns.registry, params)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, action: :validate))
     # The result belonged to the values before this change.
     |> assign(:connection, nil)}
  end

  def handle_event("save", %{"registry" => params}, socket) do
    result =
      case socket.assigns.registry do
        %Registry{id: nil} ->
          Registries.create_registry(params)

        %Registry{id: id} ->
          id |> Registries.get_registry!() |> Registries.update_registry(params)
      end

    case result do
      {:ok, registry} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Registry %{name} saved.", name: registry.name))
         |> push_navigate(to: ~p"/registries")}

      {:error, changeset} ->
        # A failed update was built from the stored registry; its password must not
        # reach the form. What the user typed may: the browser has it anyway.
        changeset = %{changeset | data: Registries.redact(changeset.data)}
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("test_connection", _params, socket) do
    params = socket.assigns.form.params
    registry_id = socket.assigns.registry.id

    {:noreply,
     socket
     |> assign(:connection, :testing)
     |> start_async(:test_connection, fn ->
       registry = if registry_id, do: Registries.get_registry!(registry_id), else: %Registry{}
       Registries.test_connection(registry, params)
     end)}
  end

  @impl true
  def handle_async(:test_connection, {:ok, result}, socket) do
    {:noreply, assign(socket, :connection, result)}
  end

  def handle_async(:test_connection, {:exit, reason}, socket) do
    {:noreply,
     assign(
       socket,
       :connection,
       {:error, gettext("The test failed: %{reason}", reason: inspect(reason))}
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:registries}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/registries"}>{gettext("Registries")}</:crumb>
            <:crumb>{if @registry.id, do: @registry.name, else: gettext("New registry")}</:crumb>
          </.breadcrumbs>
          <.page_header title={@page_title} />
        </div>

        <.form for={@form} id="registry-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="Company GitLab" />
            <.input
              field={@form[:host]}
              label={gettext("Host")}
              placeholder="registry.company.com"
              autocomplete="off"
              spellcheck="false"
              hint={
                gettext(
                  "Images starting with this host use these credentials, e.g. registry.company.com/team/e2e:1.17. Docker Hub is docker.io."
                )
              }
            />
            <div class="grid gap-5 sm:grid-cols-2">
              <.input
                field={@form[:username]}
                label={gettext("Username")}
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@form[:password]}
                type="password"
                label={gettext("Password or token")}
                autocomplete="new-password"
                hint={if @registry.id, do: gettext("Leave empty to keep the current password.")}
              />
            </div>

            <.connection_result result={@connection} />

            <:footer>
              <.button
                id="test-connection"
                type="button"
                phx-click="test_connection"
                disabled={@connection == :testing}
                class="mr-auto"
              >
                <.icon name="hero-signal-mini" class="size-4" /> {gettext("Test connection")}
              </.button>
              <.button navigate={~p"/registries"}>{gettext("Cancel")}</.button>
              <.button id="save-registry" variant="primary" phx-disable-with={gettext("Saving...")}>
                {gettext("Save")}
              </.button>
            </:footer>
          </.form_card>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  attr :result, :any, required: true

  defp connection_result(%{result: nil} = assigns), do: ~H""

  defp connection_result(assigns) do
    ~H"""
    <div
      id="connection-result"
      role="status"
      class={[
        "flex items-start gap-2.5 rounded-lg px-3.5 py-3 text-sm transition-colors duration-200",
        case @result do
          :testing -> "bg-base-200 text-base-content/70"
          :ok -> "bg-success/10 text-success"
          {:error, _} -> "bg-error/10 text-error"
        end
      ]}
    >
      <%= case @result do %>
        <% :testing -> %>
          <.icon name="hero-arrow-path-mini" class="mt-0.5 size-4 shrink-0 motion-safe:animate-spin" />
          <span id="connection-testing">{gettext("Logging in to the registry...")}</span>
        <% :ok -> %>
          <.icon name="hero-check-circle-mini" class="mt-0.5 size-4 shrink-0" />
          <span id="connection-ok">{gettext("Login succeeded. These credentials work.")}</span>
        <% {:error, message} -> %>
          <.icon name="hero-exclamation-circle-mini" class="mt-0.5 size-4 shrink-0" />
          <span id="connection-error" class="wrap-break-word">{message}</span>
      <% end %>
    </div>
    """
  end
end
