defmodule TestFleetWeb.DashboardLive do
  use TestFleetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Dashboard"))
     # There are no runs yet; these figures are wired to the Runs context with manual execution.
     |> assign(:stats, %{running: 0, passed_today: 0, failed_today: 0, timeouts: 0})}
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
            <.empty_state
              id="upcoming-schedules-empty"
              icon="hero-calendar"
              title={gettext("Nothing scheduled")}
              compact
            />
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
