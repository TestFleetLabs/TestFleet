defmodule TestFleetWeb.DashboardLive do
  use TestFleetWeb, :live_view

  alias TestFleet.Schedules

  @upcoming_limit 6

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Dashboard"))
     # There are no runs yet; these figures are wired to the Runs context with manual execution.
     |> assign(:stats, %{running: 0, passed_today: 0, failed_today: 0, timeouts: 0})
     |> stream(:upcoming, Schedules.list_upcoming(@upcoming_limit))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:dashboard}>
      <div id="dashboard" class="space-y-8">
        <.page_header
          title={gettext("Dashboard")}
          description={gettext("What is running, what failed, and what is coming up.")}
        />

        <div id="dashboard-stats" class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat_tile
            id="stat-running"
            label={gettext("Running")}
            value={@stats.running}
            icon="hero-play"
            tone={:info}
          />
          <.stat_tile
            id="stat-passed-today"
            label={gettext("Passed today")}
            value={@stats.passed_today}
            icon="hero-check"
            tone={:success}
          />
          <.stat_tile
            id="stat-failed-today"
            label={gettext("Failed today")}
            value={@stats.failed_today}
            icon="hero-x-mark"
            tone={:error}
          />
          <.stat_tile
            id="stat-timeouts"
            label={gettext("Timeouts")}
            value={@stats.timeouts}
            icon="hero-clock"
            tone={:warning}
          />
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <.panel id="recent-runs" title={gettext("Recent runs")} class="lg:col-span-2">
            <.empty_state
              id="recent-runs-empty"
              icon="hero-play-circle"
              title={gettext("No runs yet")}
              compact
            >
              {gettext("Runs show up here as soon as a test definition is executed.")}
            </.empty_state>
          </.panel>

          <.panel id="upcoming-schedules" title={gettext("Upcoming schedules")}>
            <ul id="upcoming-list" phx-update="stream" class="divide-y divide-base-300">
              <li id="upcoming-empty" class="hidden only:block">
                <.empty_state
                  id="upcoming-schedules-empty"
                  icon="hero-calendar"
                  title={gettext("Nothing scheduled")}
                  compact
                />
              </li>
              <li :for={{id, schedule} <- @streams.upcoming} id={id}>
                <.link
                  navigate={~p"/projects/#{schedule.test_definition.project.slug}"}
                  class="block px-5 py-3 transition-colors duration-150 hover:bg-base-200/40"
                >
                  <p class="truncate text-sm font-medium">{schedule.test_definition.name}</p>
                  <p class="truncate text-xs text-base-content/60">
                    {schedule.test_definition.project.name} · {schedule.environment.name}
                  </p>
                  <p class="mt-1 flex items-center gap-1.5 text-xs text-base-content/60">
                    <.icon name="hero-clock-mini" class="size-3.5" />
                    <.local_time at={schedule.next_run_at} timezone={schedule.timezone} />
                  </p>
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
