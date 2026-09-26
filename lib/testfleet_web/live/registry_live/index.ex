defmodule TestFleetWeb.RegistryLive.Index do
  use TestFleetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Registries"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:registries}>
      <div id="registries" class="space-y-8">
        <.page_header
          title={gettext("Registries")}
          description={gettext("Credentials for pulling test images, matched by registry host.")}
        />

        <.empty_state
          id="registries-empty"
          icon="hero-server-stack"
          title={gettext("No registries configured")}
        >
          {gettext("Images from registries without credentials are pulled anonymously.")}
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end
end
