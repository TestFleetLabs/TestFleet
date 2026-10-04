defmodule TestFleetWeb.ProjectLive.Index do
  use TestFleetWeb, :live_view

  alias TestFleet.Projects

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Projects"))
     |> stream(:projects, Projects.list_projects(socket.assigns.current_scope))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div id="projects" class="space-y-8">
        <.page_header
          title={gettext("Projects")}
          description={gettext("One project per application under test.")}
        >
          <:actions>
            <.button id="new-project" variant="primary" navigate={~p"/projects/new"}>
              <.icon name="hero-plus-mini" class="size-4" /> {gettext("New project")}
            </.button>
          </:actions>
        </.page_header>

        <div
          id="project-list"
          phx-update="stream"
          class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3"
        >
          <.empty_state
            id="projects-empty"
            icon="hero-folder"
            title={gettext("No projects yet")}
            class="hidden only:flex col-span-full"
          >
            {gettext(
              "A project groups the test definitions, environments, and schedules of one application."
            )}
          </.empty_state>

          <.link
            :for={{id, project} <- @streams.projects}
            id={id}
            navigate={~p"/projects/#{project.slug}"}
            class="group flex flex-col rounded-xl border border-base-300 bg-base-100 p-5 transition duration-200 hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md hover:shadow-base-300/40"
          >
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <h2 class="truncate font-semibold">{project.name}</h2>
                <p class="mt-0.5 font-mono text-xs text-base-content/50">{project.slug}</p>
              </div>
              <.icon
                name="hero-arrow-right-mini"
                class="size-5 shrink-0 text-base-content/30 transition duration-200 group-hover:translate-x-0.5 group-hover:text-primary"
              />
            </div>
            <p
              :if={project.description}
              class="mt-3 line-clamp-2 text-sm text-base-content/60"
            >
              {project.description}
            </p>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
