defmodule TestFleetWeb.StatisticsLive do
  @moduledoc """
  Admins' statistics: the organization's configuration, runs, and storage, and the
  suites holding the most artifacts. In `:single` mode also the installation: the
  database's largest tables and the Docker images TestFleet pulled. In `:multi`
  mode, an organization's admins do not see across organizations.

  The figures are read on mount and on "Refresh"; the installation's and Docker's
  load asynchronously, so a slow or unreachable Docker does not hold up the page.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{ImageCleanup, Organizations, Retention, Statistics}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Statistics"))
     |> assign(:installation?, not Organizations.multi?())
     |> load()}
  end

  defp load(socket) do
    socket =
      socket
      |> assign(:stats, Statistics.organization(socket.assigns.current_scope))
      |> assign(:refreshed_at, DateTime.utc_now())

    if socket.assigns.installation? do
      socket
      |> assign_async(:installation, fn -> {:ok, %{installation: Statistics.installation()}} end,
        reset: true
      )
      |> assign_async(:images, fn -> {:ok, %{images: Statistics.images()}} end, reset: true)
    else
      socket
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:statistics}>
      <div id="statistics" class="space-y-8">
        <.page_header
          title={gettext("Statistics")}
          description={
            if @installation?,
              do: gettext("What this installation holds, and how much space it takes."),
              else: gettext("What this organization holds, and how much space it takes.")
          }
        >
          <:actions>
            <.button
              id="refresh-statistics"
              phx-click="refresh"
              phx-disable-with={gettext("Refreshing...")}
            >
              <.icon name="hero-arrow-path-mini" class="size-4" /> {gettext("Refresh")}
            </.button>
          </:actions>
        </.page_header>

        <div id="statistics-tiles" class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.stat_tile
            id="stat-projects"
            label={gettext("Projects")}
            value={@stats.configuration.projects}
            icon="hero-folder"
          />
          <.stat_tile
            id="stat-runs"
            label={gettext("Runs")}
            value={format_count(@stats.runs.total)}
            icon="hero-play-circle"
            tone={:info}
          />
          <.stat_tile
            id="stat-artifacts"
            label={gettext("Artifacts stored")}
            value={format_size(@stats.storage.artifacts.bytes)}
            icon="hero-archive-box"
            tone={:warning}
          />
          <.stat_tile
            id="stat-logs"
            label={gettext("Logs stored")}
            value={format_size(@stats.storage.logs.bytes)}
            icon="hero-document-text"
          />
        </div>

        <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
          <.panel id="statistics-runs" title={gettext("Runs")}>
            <dl class="grid grid-cols-3 divide-x divide-base-300 border-b border-base-300 text-center">
              <.figure
                id="runs-total"
                label={gettext("total")}
                value={format_count(@stats.runs.total)}
              />
              <.figure
                id="runs-last-30-days"
                label={gettext("last 30 days")}
                value={format_count(@stats.runs.last_30_days)}
              />
              <.figure
                id="runs-pinned"
                label={gettext("pinned")}
                value={format_count(@stats.runs.pinned)}
              />
            </dl>

            <ul id="runs-by-status" class="space-y-3 px-5 py-4">
              <li
                :for={status <- TestFleet.Runs.Run.statuses()}
                :if={Map.get(@stats.runs.by_status, status, 0) > 0}
                id={"runs-#{status}"}
                class="grid grid-cols-[6.5rem_minmax(0,1fr)_4rem] items-center gap-3"
              >
                <.run_status status={status} />
                <div class="h-1.5 overflow-hidden rounded-full bg-base-200">
                  <div
                    class={["h-full rounded-full transition-[width] duration-500", status_bar(status)]}
                    style={"width: #{share(Map.get(@stats.runs.by_status, status, 0), @stats.runs.total)}%"}
                  />
                </div>
                <span class="text-right text-sm tabular-nums text-base-content/70">
                  {format_count(Map.get(@stats.runs.by_status, status, 0))}
                </span>
              </li>
              <li :if={@stats.runs.total == 0} class="text-sm text-base-content/60">
                {gettext("No runs yet.")}
              </li>
            </ul>
          </.panel>

          <.panel id="statistics-storage" title={gettext("Storage")}>
            <dl class="divide-y divide-base-300 text-sm">
              <.row id="storage-artifacts" label={gettext("Artifacts")}>
                {format_size(@stats.storage.artifacts.bytes)}
                <:detail>
                  {ngettext("1 file", "%{count} files", @stats.storage.artifacts.files)} · {ngettext(
                    "1 run",
                    "%{count} runs",
                    @stats.storage.artifacts.runs
                  )}
                </:detail>
              </.row>
              <.row id="storage-logs" label={gettext("Logs")}>
                {format_size(@stats.storage.logs.bytes)}
                <:detail>{ngettext("1 run", "%{count} runs", @stats.storage.logs.runs)}</:detail>
              </.row>
              <.row id="storage-test-results" label={gettext("Test results")}>
                {format_count(@stats.storage.test_results)}
                <:detail>{gettext("always kept")}</:detail>
              </.row>
              <.row id="storage-expired" label={gettext("Expired")}>
                {ngettext("1 run", "%{count} runs", @stats.storage.artifacts_expired)}
                <:detail>{gettext("artifacts removed by retention")}</:detail>
              </.row>
              <.row id="storage-retention" label={gettext("Retention")}>
                {gettext("artifacts %{artifacts} days, logs %{logs} days",
                  artifacts: Retention.artifacts_days(),
                  logs: Retention.logs_days()
                )}
                <:detail>{gettext("default; test definitions can override it")}</:detail>
              </.row>
            </dl>
          </.panel>

          <.panel id="statistics-largest-suites" title={gettext("Largest suites by artifacts")}>
            <ul class="divide-y divide-base-300">
              <li :if={@stats.largest_suites == []}>
                <.empty_state
                  id="largest-suites-empty"
                  icon="hero-archive-box"
                  title={gettext("No artifacts stored")}
                  compact
                />
              </li>
              <li :for={suite <- @stats.largest_suites} id={"largest-suite-#{suite.id}"}>
                <.link
                  navigate={
                    ~p"/#{@organization}/projects/#{suite.project_slug}/test-definitions/#{suite.id}"
                  }
                  class="flex items-center gap-4 px-5 py-3 transition-colors duration-150 hover:bg-base-200/40"
                >
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-sm font-medium">{suite.name}</p>
                    <p class="truncate text-xs text-base-content/60">
                      {suite.project_name} · {ngettext("1 run", "%{count} runs", suite.runs)} · {retention_label(
                        suite.artifact_retention_days
                      )}
                    </p>
                  </div>
                  <div class="w-24 shrink-0 space-y-1 text-right">
                    <p class="text-sm font-medium tabular-nums">{format_size(suite.bytes)}</p>
                    <div class="h-1 overflow-hidden rounded-full bg-base-200">
                      <div
                        class="ml-auto h-full rounded-full bg-warning/70"
                        style={"width: #{share(suite.bytes, @stats.storage.artifacts.bytes)}%"}
                      />
                    </div>
                  </div>
                </.link>
              </li>
            </ul>
          </.panel>

          <.panel id="statistics-configuration" title={gettext("Configuration")}>
            <dl class="divide-y divide-base-300 text-sm">
              <.row id="configuration-projects" label={gettext("Projects")}>
                {@stats.configuration.projects}
              </.row>
              <.row id="configuration-test-definitions" label={gettext("Test definitions")}>
                {elem(@stats.configuration.test_definitions, 0)}
                <:detail>
                  {gettext("%{count} enabled", count: elem(@stats.configuration.test_definitions, 1))}
                </:detail>
              </.row>
              <.row id="configuration-environments" label={gettext("Environments")}>
                {@stats.configuration.environments}
              </.row>
              <.row id="configuration-schedules" label={gettext("Schedules")}>
                {elem(@stats.configuration.schedules, 0)}
                <:detail>
                  {gettext("%{count} enabled", count: elem(@stats.configuration.schedules, 1))}
                </:detail>
              </.row>
              <.row id="configuration-members" label={gettext("Members")}>
                {@stats.configuration.members}
              </.row>
            </dl>
          </.panel>
        </div>

        <section :if={@installation?} id="statistics-installation" class="space-y-6">
          <div class="border-b border-base-300 pb-3">
            <h2 class="text-lg font-semibold tracking-tight">{gettext("Installation")}</h2>
            <p class="mt-1 text-sm text-base-content/60">
              {gettext("The database and the Docker host, across everything TestFleet stores.")}
            </p>
          </div>

          <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
            <.panel id="installation-database" title={gettext("Database")}>
              <.async_result :let={installation} assign={@installation}>
                <:loading><.loading_rows /></:loading>
                <:failed :let={_failure}>
                  <p id="installation-database-failed" class="px-5 py-4 text-sm text-error">
                    {gettext("The database figures could not be read.")}
                  </p>
                </:failed>

                <dl class="grid grid-cols-3 divide-x divide-base-300 border-b border-base-300 text-center">
                  <.figure
                    id="database-size"
                    label={gettext("database")}
                    value={format_size(installation.database_bytes)}
                  />
                  <.figure
                    id="database-artifacts"
                    label={gettext("artifacts on disk")}
                    value={format_size(installation.artifacts.bytes)}
                  />
                  <.figure
                    id="database-users"
                    label={gettext("active users")}
                    value={format_count(installation.users)}
                  />
                </dl>

                <table id="database-tables" class="w-full text-sm">
                  <thead>
                    <tr class="text-left text-xs text-base-content/50">
                      <th class="px-5 py-2 font-medium">{gettext("Table")}</th>
                      <th class="px-5 py-2 text-right font-medium">{gettext("Rows (approx.)")}</th>
                      <th class="px-5 py-2 text-right font-medium">{gettext("Size")}</th>
                    </tr>
                  </thead>
                  <tbody class="divide-y divide-base-300">
                    <tr :for={table <- installation.tables} id={"table-#{table.name}"}>
                      <td class="px-5 py-2 font-mono text-xs">{table.name}</td>
                      <td class="px-5 py-2 text-right tabular-nums text-base-content/70">
                        {format_count(table.rows)}
                      </td>
                      <td class="px-5 py-2 text-right tabular-nums">{format_size(table.bytes)}</td>
                    </tr>
                  </tbody>
                </table>
              </.async_result>
            </.panel>

            <.panel id="installation-images" title={gettext("Docker images")}>
              <.async_result :let={images} assign={@images}>
                <:loading><.loading_rows /></:loading>
                <:failed :let={_failure}>
                  <p id="installation-images-failed" class="px-5 py-4 text-sm text-error">
                    {gettext("The image figures could not be read.")}
                  </p>
                </:failed>

                <%= case images do %>
                  <% {:ok, usage} -> %>
                    <dl id="images-usage" class="divide-y divide-base-300 text-sm">
                      <.row id="images-testfleet" label={gettext("Pulled by TestFleet")}>
                        {format_size(usage.bytes)}
                        <:detail>{ngettext("1 image", "%{count} images", usage.count)}</:detail>
                      </.row>
                      <.row id="images-host" label={gettext("All images on the host")}>
                        {format_size(usage.host_bytes)}
                        <:detail>{ngettext("1 image", "%{count} images", usage.host_count)}</:detail>
                      </.row>
                      <.row id="images-retention" label={gettext("Cleanup")}>
                        {ngettext(
                          "after 1 unused day",
                          "after %{count} unused days",
                          ImageCleanup.retention_days()
                        )}
                        <:detail>{gettext("TestFleet's images only, by digest")}</:detail>
                      </.row>
                    </dl>
                    <p class="border-t border-base-300 px-5 py-3 text-xs text-base-content/60">
                      {gettext(
                        "Sizes as Docker reports them: layers shared between images count once per image."
                      )}
                    </p>
                  <% {:error, error} -> %>
                    <div id="images-unreachable" class="flex items-start gap-3 px-5 py-4">
                      <.icon
                        name="hero-exclamation-triangle"
                        class="mt-0.5 size-5 shrink-0 text-warning"
                      />
                      <div class="min-w-0 space-y-1">
                        <p class="text-sm font-medium">{gettext("Docker is not reachable.")}</p>
                        <p class="break-words font-mono text-xs text-base-content/60">
                          {error.message}
                        </p>
                      </div>
                    </div>
                <% end %>
              </.async_result>
            </.panel>
          </div>
        </section>

        <p class="text-xs text-base-content/50">
          {gettext("As of %{time} UTC.", time: Calendar.strftime(@refreshed_at, "%Y-%m-%d %H:%M:%S"))}
        </p>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp figure(assigns) do
    ~H"""
    <div id={@id} class="px-3 py-4">
      <dd class="text-xl font-semibold tracking-tight tabular-nums">{@value}</dd>
      <dt class="mt-0.5 text-xs text-base-content/60">{@label}</dt>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :detail

  defp row(assigns) do
    ~H"""
    <div id={@id} class="grid grid-cols-[8rem_minmax(0,1fr)] gap-3 px-5 py-3">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="min-w-0">
        <span class="font-medium tabular-nums">{render_slot(@inner_block)}</span>
        <span :if={@detail != []} class="block text-xs text-base-content/60">
          {render_slot(@detail)}
        </span>
      </dd>
    </div>
    """
  end

  defp loading_rows(assigns) do
    ~H"""
    <div class="space-y-3 px-5 py-4" aria-busy="true">
      <div
        :for={width <- ~w(w-2/3 w-1/2 w-3/4)}
        class={["h-3 animate-pulse rounded bg-base-200", width]}
      />
    </div>
    """
  end

  defp retention_label(nil),
    do: gettext("kept %{count} days (default)", count: Retention.artifacts_days())

  defp retention_label(days), do: ngettext("kept 1 day", "kept %{count} days", days)

  # Percent of `total`, at least a sliver for anything above zero.
  defp share(_part, 0), do: 0
  defp share(0, _total), do: 0
  defp share(part, total), do: max(Float.round(part * 100 / total, 1), 1)

  defp status_bar(:passed), do: "bg-success"
  defp status_bar(:failed), do: "bg-error"
  defp status_bar(:error), do: "bg-error/60"
  defp status_bar(:timeout), do: "bg-warning"
  defp status_bar(status) when status in [:preparing, :running], do: "bg-info"
  defp status_bar(_status), do: "bg-base-content/30"

  # 1234567 as "1,234,567".
  defp format_count(count) do
    count
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end
end
