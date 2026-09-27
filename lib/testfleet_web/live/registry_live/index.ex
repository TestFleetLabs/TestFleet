defmodule TestFleetWeb.RegistryLive.Index do
  @moduledoc """
  Registry credentials. Passwords never reach the browser: registries are redacted
  before they are streamed.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Registries

  @impl true
  def mount(_params, _session, socket) do
    registries = Enum.map(Registries.list_registries(), &Registries.redact/1)

    {:ok,
     socket
     |> assign(:page_title, gettext("Registries"))
     |> assign(:registry_count, length(registries))
     |> stream(:registries, registries)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    registry = Registries.get_registry!(id)
    {:ok, _} = Registries.delete_registry(registry)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Registry %{name} deleted.", name: registry.name))
     |> update(:registry_count, &(&1 - 1))
     |> stream_delete(:registries, registry)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:registries}>
      <div id="registries" class="space-y-8">
        <.page_header
          title={gettext("Registries")}
          description={gettext("Credentials for pulling test images, matched by registry host.")}
        >
          <:actions>
            <.button id="new-registry" variant="primary" navigate={~p"/registries/new"}>
              <.icon name="hero-plus-mini" class="size-4" /> {gettext("New registry")}
            </.button>
          </:actions>
        </.page_header>

        <.empty_state
          :if={@registry_count == 0}
          id="registries-empty"
          icon="hero-server-stack"
          title={gettext("No registries configured")}
        >
          {gettext("Images from registries without credentials are pulled anonymously.")}
        </.empty_state>

        <div
          :if={@registry_count > 0}
          class="overflow-x-auto rounded-xl border border-base-300 bg-base-100"
        >
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 text-xs font-medium tracking-wide text-base-content/60 uppercase">
              <tr>
                <th class="px-5 py-3 font-medium">{gettext("Name")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Host")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Username")}</th>
                <th class="px-5 py-3"><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody id="registry-list" phx-update="stream" class="divide-y divide-base-300">
              <tr
                :for={{id, registry} <- @streams.registries}
                id={id}
                class="transition-colors duration-150 hover:bg-base-200/40"
              >
                <td class="px-5 py-3 font-medium">{registry.name}</td>
                <td class="px-5 py-3">
                  <.badge class="font-mono">{registry.host}</.badge>
                </td>
                <td class="px-5 py-3 font-mono text-xs text-base-content/70">
                  {registry.username}
                </td>
                <td class="w-0 px-5 py-2">
                  <div class="flex items-center justify-end gap-1">
                    <.button
                      id={"edit-registry-#{registry.id}"}
                      variant="ghost"
                      size="sm"
                      navigate={~p"/registries/#{registry.id}/edit"}
                      aria-label={gettext("Edit %{name}", name: registry.name)}
                    >
                      <.icon name="hero-pencil-square-mini" class="size-4" />
                    </.button>
                    <.button
                      id={"delete-registry-#{registry.id}"}
                      variant="ghost"
                      size="sm"
                      phx-click="delete"
                      phx-value-id={registry.id}
                      data-confirm={
                        gettext(
                          "Delete the credentials for %{host}? Its images will be pulled anonymously.",
                          host: registry.host
                        )
                      }
                      aria-label={gettext("Delete %{name}", name: registry.name)}
                    >
                      <.icon name="hero-trash-mini" class="size-4" />
                    </.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
