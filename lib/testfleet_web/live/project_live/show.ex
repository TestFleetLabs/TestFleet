defmodule TestFleetWeb.ProjectLive.Show do
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    project = Projects.get_project_by_slug!(slug)

    {:ok,
     socket
     |> assign(:page_title, project.name)
     |> assign(:project, project)
     |> stream(:environments, Environments.list_environments(project))}
  end

  @impl true
  def handle_event("delete", _params, socket) do
    {:ok, project} = Projects.delete_project(socket.assigns.project)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Project %{name} deleted.", name: project.name))
     |> push_navigate(to: ~p"/projects")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <div id="project" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/projects"}>{gettext("Projects")}</:crumb>
            <:crumb>{@project.name}</:crumb>
          </.breadcrumbs>

          <.page_header title={@project.name} description={@project.description}>
            <:actions>
              <.button id="edit-project" navigate={~p"/projects/#{@project.slug}/edit"}>
                <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
              </.button>
              <.button
                id="delete-project"
                variant="danger"
                phx-click="delete"
                data-confirm={
                  gettext(
                    "Delete %{name} with all its test definitions, environments, and schedules?",
                    name: @project.name
                  )
                }
              >
                <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
              </.button>
            </:actions>
          </.page_header>
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.panel id="test-definitions" title={gettext("Test definitions")}>
            <.empty_state
              id="test-definitions-empty"
              icon="hero-beaker"
              title={gettext("No test definitions yet")}
              compact
            >
              {gettext("A test definition names the image that contains the test suite.")}
            </.empty_state>
          </.panel>

          <.panel id="environments" title={gettext("Environments")}>
            <:actions>
              <.button
                id="new-environment"
                variant="ghost"
                size="sm"
                navigate={~p"/projects/#{@project.slug}/environments/new"}
              >
                <.icon name="hero-plus-mini" class="size-4" /> {gettext("New")}
              </.button>
            </:actions>

            <ul id="environment-list" phx-update="stream" class="divide-y divide-base-300">
              <li id="environments-empty" class="hidden only:block">
                <.empty_state
                  id="environments-empty-state"
                  icon="hero-globe-alt"
                  title={gettext("No environments yet")}
                  compact
                >
                  {gettext(
                    "An environment holds the variables that point a suite at a target system."
                  )}
                </.empty_state>
              </li>
              <li :for={{id, environment} <- @streams.environments} id={id}>
                <.link
                  navigate={~p"/projects/#{@project.slug}/environments/#{environment.slug}"}
                  class="group flex items-center justify-between gap-3 px-5 py-3 transition-colors duration-150 hover:bg-base-200/40"
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium">{environment.name}</p>
                    <p class="font-mono text-xs text-base-content/50">{environment.slug}</p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <.badge>
                      {ngettext("1 variable", "%{count} variables", environment.variable_count)}
                    </.badge>
                    <.icon
                      name="hero-chevron-right-mini"
                      class="size-4 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-primary"
                    />
                  </div>
                </.link>
              </li>
            </ul>
          </.panel>

          <.panel id="schedules" title={gettext("Schedules")} class="lg:col-span-2">
            <.empty_state
              id="schedules-empty"
              icon="hero-calendar"
              title={gettext("No schedules yet")}
              compact
            >
              {gettext("A schedule runs a test definition against an environment at fixed times.")}
            </.empty_state>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
