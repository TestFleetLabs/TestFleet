defmodule TestFleetWeb.ProjectLive.Show do
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Schedules, TestDefinitions}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    project = Projects.get_project_by_slug!(slug)

    {:ok,
     socket
     |> assign(:page_title, project.name)
     |> assign(:project, project)
     |> stream(:test_definitions, TestDefinitions.list_test_definitions(project))
     |> stream(:environments, Environments.list_environments(project))
     |> stream(:schedules, Schedules.list_schedules(project))}
  end

  defp overlap_label(:queue), do: gettext("queues overlaps")
  defp overlap_label(:allow), do: gettext("runs in parallel")

  @impl true
  def handle_event("delete", _params, socket) do
    case Projects.delete_project(socket.assigns.project) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Project %{name} deleted.", name: project.name))
         |> push_navigate(to: ~p"/projects")}

      {:error, :has_runs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("This project has runs and cannot be deleted; its run history would be lost.")
         )}
    end
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
            <:actions>
              <.button
                id="new-test-definition"
                variant="ghost"
                size="sm"
                navigate={~p"/projects/#{@project.slug}/test-definitions/new"}
              >
                <.icon name="hero-plus-mini" class="size-4" /> {gettext("New")}
              </.button>
            </:actions>

            <ul id="test-definition-list" phx-update="stream" class="divide-y divide-base-300">
              <li id="test-definitions-empty" class="hidden only:block">
                <.empty_state
                  id="test-definitions-empty-state"
                  icon="hero-beaker"
                  title={gettext("No test definitions yet")}
                  compact
                >
                  {gettext("A test definition names the image that contains the test suite.")}
                </.empty_state>
              </li>
              <li :for={{id, test_definition} <- @streams.test_definitions} id={id}>
                <.link
                  navigate={~p"/projects/#{@project.slug}/test-definitions/#{test_definition.id}"}
                  class={[
                    "group flex items-center justify-between gap-3 px-5 py-3 transition-colors duration-150 hover:bg-base-200/40",
                    !test_definition.enabled && "opacity-60 hover:opacity-100"
                  ]}
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium">{test_definition.name}</p>
                    <p
                      class="truncate font-mono text-xs text-base-content/50"
                      title={test_definition.image}
                    >
                      {test_definition.image}
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <.badge :if={!test_definition.enabled} tone={:warning}>
                      {gettext("disabled")}
                    </.badge>
                    <.badge title={gettext("Timeout")}>
                      <.icon name="hero-clock-mini" class="size-3.5" />
                      {format_timeout(test_definition.timeout_seconds)}
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
            <:actions>
              <.button
                id="new-schedule"
                variant="ghost"
                size="sm"
                navigate={~p"/projects/#{@project.slug}/schedules/new"}
              >
                <.icon name="hero-plus-mini" class="size-4" /> {gettext("New")}
              </.button>
            </:actions>

            <ul id="schedule-list" phx-update="stream" class="divide-y divide-base-300">
              <li id="schedules-empty" class="hidden only:block">
                <.empty_state
                  id="schedules-empty-state"
                  icon="hero-calendar"
                  title={gettext("No schedules yet")}
                  compact
                >
                  {gettext("A schedule runs a test definition against an environment at fixed times.")}
                </.empty_state>
              </li>
              <li :for={{id, schedule} <- @streams.schedules} id={id}>
                <.link
                  navigate={~p"/projects/#{@project.slug}/schedules/#{schedule.id}/edit"}
                  class={[
                    "group flex flex-wrap items-center justify-between gap-x-4 gap-y-2 px-5 py-3 transition-colors duration-150 hover:bg-base-200/40",
                    !schedule.enabled && "opacity-60 hover:opacity-100"
                  ]}
                >
                  <div class="min-w-0">
                    <p class="flex items-center gap-1.5 truncate text-sm font-medium">
                      {schedule.test_definition.name}
                      <.icon name="hero-arrow-right-mini" class="size-3.5 text-base-content/40" />
                      {schedule.environment.name}
                    </p>
                    <p class="font-mono text-xs text-base-content/50">
                      {schedule.cron_expression}
                      <span class="font-sans">· {schedule.timezone}</span>
                    </p>
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <.badge :if={schedule.overlap_policy != :skip}>
                      {overlap_label(schedule.overlap_policy)}
                    </.badge>
                    <.badge :if={!schedule.enabled} tone={:warning}>{gettext("disabled")}</.badge>
                    <span
                      :if={schedule.enabled}
                      class="flex items-center gap-1.5 text-xs text-base-content/60"
                    >
                      <.icon name="hero-clock-mini" class="size-3.5" />
                      <.local_time at={schedule.next_run_at} timezone={schedule.timezone} />
                    </span>
                    <.icon
                      name="hero-chevron-right-mini"
                      class="size-4 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-primary"
                    />
                  </div>
                </.link>
              </li>
            </ul>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
