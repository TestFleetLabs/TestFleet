defmodule TestFleetWeb.DashboardLive do
  @moduledoc """
  The dashboard: today's figures, recent and queued runs, and
  upcoming schedules. Runs update live from the `runs` topic, Docker's reachability
  from the `system` topic.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Execution, Runs, Schedules}
  alias TestFleet.Schedules.Timezones
  alias TestFleetWeb.RunFeed

  @upcoming_limit 6
  @recent_limit 10
  @queue_limit 10
  # "Today" ends at midnight even when no run changes.
  @stats_refresh :timer.minutes(1)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Runs.subscribe()
      Execution.subscribe_system()
      :timer.send_interval(@stats_refresh, :refresh_stats)
    end

    {:ok,
     socket
     |> assign(:page_title, gettext("Dashboard"))
     |> assign(:timezone, Timezones.default())
     |> assign(:docker, Execution.docker_status())
     |> assign_stats()
     |> assign_queue()
     |> RunFeed.init(:recent, Runs.list_runs(limit: @recent_limit))
     |> assign_upcoming()}
  end

  # A schedule this late means the tick is not running.
  @overdue_after_seconds 120

  defp assign_upcoming(socket) do
    socket
    |> assign(:overdue_before, DateTime.add(DateTime.utc_now(), -@overdue_after_seconds))
    |> stream(:upcoming, Schedules.list_upcoming(@upcoming_limit), reset: true)
  end

  defp assign_stats(socket),
    do: assign(socket, :stats, Runs.dashboard_stats(socket.assigns.timezone))

  # The queue is reloaded rather than patched: when a run leaves it, the next
  # waiting run moves up into the list.
  defp assign_queue(socket) do
    runs = Runs.list_runs(statuses: [:queued], oldest_first: true, limit: @queue_limit)

    socket
    |> assign(:queued_ids, Enum.map(runs, & &1.id))
    |> stream(:queued, runs, reset: true)
  end

  @impl true
  def handle_info({event, run} = message, socket)
      when event in [:run_created, :run_updated, :run_finished] do
    socket =
      if run.status == :queued or run.id in socket.assigns.queued_ids,
        do: assign_queue(socket),
        else: socket

    # A scheduled run means its schedule moved to its next time.
    socket =
      if event == :run_created and run.schedule_id, do: assign_upcoming(socket), else: socket

    {:noreply,
     socket
     |> assign_stats()
     |> RunFeed.apply_event(:recent, message, @recent_limit)}
  end

  def handle_info(:refresh_stats, socket),
    do: {:noreply, socket |> assign_stats() |> assign_upcoming()}

  def handle_info({:docker_status, status}, socket),
    do: {:noreply, assign(socket, :docker, status)}

  attr :status, :map, required: true
  attr :timezone, :string, required: true

  defp docker_banner(assigns) do
    ~H"""
    <div
      id="docker-unreachable"
      role="alert"
      class="flex items-start gap-3 rounded-xl border border-warning/40 bg-warning/10 px-5 py-4"
    >
      <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
      <div class="min-w-0 space-y-1">
        <p class="text-sm font-semibold">
          {gettext("Docker is not reachable since %{time}.",
            time: Calendar.strftime(DateTime.shift_zone!(@status.since, @timezone), "%H:%M")
          )}
          <span class="font-normal text-base-content/70">
            {gettext("Queued runs wait until it is back.")}
          </span>
        </p>
        <p
          :if={@status.message}
          id="docker-unreachable-message"
          class="break-words font-mono text-xs text-base-content/60"
        >
          {@status.message}
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:dashboard}>
      <div id="dashboard" class="space-y-8">
        <.page_header
          title={gettext("Dashboard")}
          description={gettext("What is running, what failed, and what is coming up.")}
        />

        <.docker_banner :if={not @docker.reachable} status={@docker} timezone={@timezone} />

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
            id="stat-timeouts-today"
            label={gettext("Timeouts today")}
            value={@stats.timeouts_today}
            icon="hero-clock"
            tone={:warning}
          />
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
          <.panel id="recent-runs" title={gettext("Recent runs")} class="lg:col-span-2">
            <:actions>
              <.button id="all-runs" variant="ghost" size="sm" navigate={~p"/runs"}>
                {gettext("All runs")} <.icon name="hero-arrow-right-mini" class="size-4" />
              </.button>
            </:actions>

            <ul id="recent-run-list" phx-update="stream" class="divide-y divide-base-300">
              <li id="recent-runs-empty" class="hidden only:block">
                <.empty_state
                  id="recent-runs-empty-state"
                  icon="hero-play-circle"
                  title={gettext("No runs yet")}
                  compact
                >
                  {gettext("Runs show up here as soon as a test definition is executed.")}
                </.empty_state>
              </li>
              <.run_row :for={{id, run} <- @streams.recent} id={id} run={run} />
            </ul>
          </.panel>

          <div class="space-y-6">
            <.panel id="queued-runs" title={gettext("Queued runs")}>
              <:actions>
                <.badge
                  :if={@stats.queued > 0 and not @docker.reachable}
                  id="queued-waiting-for-docker"
                  tone={:warning}
                >
                  <.icon name="hero-pause-mini" class="size-3.5" />
                  {gettext("waiting for Docker")}
                </.badge>
                <.badge :if={@stats.queued > 0} id="queued-count">{@stats.queued}</.badge>
              </:actions>

              <ul id="queued-run-list" phx-update="stream" class="divide-y divide-base-300">
                <li id="queued-runs-empty" class="hidden only:block">
                  <.empty_state
                    id="queued-runs-empty-state"
                    icon="hero-queue-list"
                    title={gettext("Nothing waiting")}
                    compact
                  >
                    {gettext("Runs wait here while their environment or TestFleet is at its limit.")}
                  </.empty_state>
                </li>
                <.run_row :for={{id, run} <- @streams.queued} id={id} run={run} />
              </ul>
              <p
                :if={@stats.queued > length(@queued_ids)}
                id="queued-more"
                class="border-t border-base-300 px-5 py-3 text-xs text-base-content/60"
              >
                {ngettext(
                  "and 1 more waiting",
                  "and %{count} more waiting",
                  @stats.queued - length(@queued_ids)
                )}
              </p>
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
                      <.badge
                        :if={DateTime.before?(schedule.next_run_at, @overdue_before)}
                        id={"schedule-#{schedule.id}-overdue"}
                        tone={:warning}
                        title={
                          gettext(
                            "Scheduling is not running: the schedule tick has not picked this up."
                          )
                        }
                      >
                        {gettext("overdue")}
                      </.badge>
                    </p>
                  </.link>
                </li>
              </ul>
            </.panel>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
