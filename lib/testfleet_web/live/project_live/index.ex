defmodule TestFleetWeb.ProjectLive.Index do
  use TestFleetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Projects"))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <div id="projects" class="space-y-8">
        <.page_header
          title={gettext("Projects")}
          description={gettext("One project per application under test.")}
        />

        <.empty_state id="projects-empty" icon="hero-folder" title={gettext("No projects yet")}>
          {gettext(
            "A project groups the test definitions, environments, and schedules of one application."
          )}
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end
end
