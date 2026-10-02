defmodule TestFleetWeb.RunLive.Show do
  @moduledoc """
  The run page (main spec sections 23 and 42): status, timing, and what was
  executed, updated live from `run:<id>`. Log output arrives with Milestone 4.
  """
  use TestFleetWeb, :live_view

  import TestFleetWeb.NotificationComponents, only: [delivery_status: 1]

  alias TestFleet.{Artifacts, Notifications, Results, Runs, Schedules}
  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.Timezones

  # Lines loaded on mount, and the most kept in the page (Milestone 4, section 8).
  @history_lines 1_000
  @max_lines 2_000
  # Images and videos previewed above the artifact list; all are in the list.
  @max_media 24

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run!(id)

    # Subscribed before the history is loaded: a batch that overlaps it updates
    # the same lines (DOM id `log-<sequence>`) instead of repeating them.
    if connected?(socket) do
      Runs.subscribe(run.id)
      Notifications.subscribe_deliveries()
    end

    lines = Runs.list_log_tail(run, @history_lines)
    deliveries = Notifications.list_run_deliveries(run)

    {:ok,
     socket
     |> assign(:page_title, gettext("Run #%{id}", id: run.id))
     |> assign(:timezone, Timezones.default())
     |> assign(:ticking, false)
     |> assign(:first_sequence, (List.first(lines) || %{sequence: 1}).sequence)
     |> assign(:line_count, max(run.last_log_sequence, length(lines)))
     |> assign(:max_lines, @max_lines)
     # Loaded once: a run never changes its schedule. Nil if it was deleted.
     |> assign(:schedule, run.schedule_id && Schedules.get_schedule(run.schedule_id))
     |> stream_configure(:log_lines, dom_id: &"log-#{&1.sequence}")
     |> stream(:log_lines, lines)
     |> assign(
       results_loaded: false,
       show_all_tests: false,
       tests_duration_ms: nil,
       artifact_count: 0,
       artifact_bytes: 0,
       media_count: 0,
       max_media: @max_media
     )
     |> stream(:test_failures, [])
     |> stream(:test_others, [])
     |> stream(:media, [])
     |> stream(:artifact_rows, [])
     # Notifications this run caused (Milestone 8, section 9)
     |> assign(:delivery_ids, MapSet.new(deliveries, & &1.id))
     |> assign(:delivery_count, length(deliveries))
     |> stream_configure(:run_deliveries, dom_id: &"run-delivery-#{&1.id}")
     |> stream(:run_deliveries, deliveries)
     |> assign_run(run)}
  end

  # While the run is active, the duration counts up once a second. Results and
  # artifacts are stored with the final status, so they are loaded once it is.
  defp assign_run(socket, run) do
    socket =
      socket
      |> assign(run: run, now: DateTime.utc_now())
      |> maybe_load_results()

    counting? = run.started_at != nil and not Run.final?(run)

    if connected?(socket) and counting? and not socket.assigns.ticking do
      Process.send_after(self(), :tick, 1000)
      assign(socket, :ticking, true)
    else
      socket
    end
  end

  defp maybe_load_results(%{assigns: %{results_loaded: false, run: run}} = socket) do
    if Run.final?(run) do
      artifacts = Artifacts.list_artifacts(run)
      media = Enum.filter(artifacts, &(artifact_kind(&1) in [:image, :video]))
      junit? = run.tests_passed != nil

      socket
      |> assign(
        results_loaded: true,
        tests_duration_ms: if(junit?, do: Results.total_duration_ms(run)),
        artifact_count: length(artifacts),
        artifact_bytes: Enum.sum_by(artifacts, & &1.size_bytes),
        media_count: length(media)
      )
      |> stream(
        :test_failures,
        if(junit?, do: Results.list_test_results(run, only: :failures), else: []),
        reset: true
      )
      |> stream(:media, Enum.take(media, @max_media), reset: true)
      |> stream(:artifact_rows, artifact_tree(artifacts), reset: true)
    else
      socket
    end
  end

  defp maybe_load_results(socket), do: socket

  # Retention expired the artifacts or the log while the page is open.
  defp clear_expired(socket, %Run{} = old, %Run{} = new) do
    socket =
      if is_nil(old.artifacts_expired_at) and new.artifacts_expired_at do
        socket
        |> assign(artifact_count: 0, artifact_bytes: 0, media_count: 0)
        |> stream(:media, [], reset: true)
        |> stream(:artifact_rows, [], reset: true)
      else
        socket
      end

    if is_nil(old.logs_expired_at) and new.logs_expired_at,
      do: stream(socket, :log_lines, [], reset: true),
      else: socket
  end

  @impl true
  def handle_event("toggle_pin", _params, socket) do
    {:ok, run} = Runs.set_pinned(socket.assigns.run, !socket.assigns.run.pinned)
    {:noreply, assign_run(socket, run)}
  end

  def handle_event("show_all_tests", _params, socket) do
    others = Results.list_test_results(socket.assigns.run, only: :others)

    {:noreply,
     socket
     |> assign(:show_all_tests, true)
     |> stream(:test_others, others, reset: true)}
  end

  def handle_event("cancel", _params, socket) do
    :ok = Runs.cancel_run(socket.assigns.run)
    # A queued run is cancelled now. An active one records the request (shown as
    # "Cancelling…", also after a reload) and stops its container first, up to the
    # grace period; the final status arrives through `run:<id>`.
    {:noreply, assign_run(socket, Runs.get_run!(socket.assigns.run.id))}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = assign(socket, :ticking, false)
    {:noreply, assign_run(socket, socket.assigns.run)}
  end

  def handle_info({event, %Run{id: id} = run}, %{assigns: %{run: %Run{id: id}}} = socket)
      when event in [:run_created, :run_updated, :run_finished] do
    {:noreply,
     socket
     |> clear_expired(socket.assigns.run, run)
     |> assign_run(run)}
  end

  def handle_info(
        {:delivery, %{run_id: run_id} = delivery},
        %{assigns: %{run: %{id: run_id}}} = socket
      ) do
    ids = MapSet.put(socket.assigns.delivery_ids, delivery.id)

    {:noreply,
     socket
     |> assign(delivery_ids: ids, delivery_count: MapSet.size(ids))
     |> stream_insert(:run_deliveries, delivery)}
  end

  # Another run's, or a system event's.
  def handle_info({:delivery, _delivery}, socket), do: {:noreply, socket}

  def handle_info({:run_output, lines}, socket) do
    {:noreply,
     socket
     |> update(:line_count, &max(&1, List.last(lines).sequence))
     |> stream(:log_lines, lines, limit: -@max_lines)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:runs}>
      <div id="run" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/runs"}>{gettext("Runs")}</:crumb>
            <:crumb>#{@run.id}</:crumb>
          </.breadcrumbs>

          <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300 pb-6">
            <div class="min-w-0 space-y-2">
              <div class="flex flex-wrap items-center gap-3">
                <h1 class="text-2xl font-semibold tracking-tight">
                  {gettext("Run #%{id}", id: @run.id)}
                </h1>
                <.run_status id="run-status" status={@run.status} size={:lg} />
              </div>
              <p class="flex flex-wrap items-center gap-1.5 text-sm text-base-content/60">
                <.link
                  id="run-test-definition"
                  navigate={
                    ~p"/projects/#{@run.test_definition.project.slug}/test-definitions/#{@run.test_definition.id}"
                  }
                  class="font-medium text-base-content/80 transition-colors hover:text-primary"
                >
                  {@run.test_definition.name}
                </.link>
                <.icon name="hero-arrow-right-mini" class="size-3.5 text-base-content/40" />
                <.link
                  id="run-environment"
                  navigate={
                    ~p"/projects/#{@run.test_definition.project.slug}/environments/#{@run.environment.slug}"
                  }
                  class="font-medium text-base-content/80 transition-colors hover:text-primary"
                >
                  {@run.environment.name}
                </.link>
                <span>·</span>
                <.link
                  navigate={~p"/projects/#{@run.test_definition.project.slug}"}
                  class="transition-colors hover:text-base-content"
                >
                  {@run.test_definition.project.name}
                </.link>
              </p>
            </div>

            <.button
              :if={@run.cancel_requested_at && !Run.final?(@run)}
              id="cancelling-run"
              variant="danger"
              disabled
            >
              <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
              {gettext("Cancelling…")}
            </.button>
            <.button
              :if={!@run.cancel_requested_at and !Run.final?(@run)}
              id="cancel-run"
              variant="danger"
              phx-click="cancel"
              data-confirm={gettext("Cancel run #%{id}?", id: @run.id)}
            >
              <.icon name="hero-stop-mini" class="size-4" /> {gettext("Cancel run")}
            </.button>
            <.button
              :if={Run.final?(@run)}
              id="pin-run"
              variant={if(@run.pinned, do: "primary", else: "secondary")}
              phx-click="toggle_pin"
              aria-pressed={to_string(@run.pinned)}
              title={
                if(@run.pinned,
                  do: gettext("Pinned: kept by retention. Click to unpin."),
                  else: gettext("Pin to keep the artifacts and log beyond retention")
                )
              }
            >
              <.icon
                name={if(@run.pinned, do: "hero-bookmark-solid", else: "hero-bookmark")}
                class="size-4"
              />
              {if(@run.pinned, do: gettext("Pinned"), else: gettext("Pin"))}
            </.button>
          </div>
        </div>

        <div
          :if={@run.error_message}
          id="run-error"
          class="flex items-start gap-3 rounded-xl border border-base-300 bg-base-200/60 px-5 py-4 text-sm"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-5 shrink-0 text-warning" />
          <div class="min-w-0">
            <p class="font-medium">{gettext("TestFleet could not execute this run")}</p>
            <p class="mt-1 font-mono text-xs break-words text-base-content/70">
              {@run.error_message}
            </p>
          </div>
        </div>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.fact id="run-queued-at" label={gettext("Queued")}>
            <.local_time at={@run.queued_at} timezone={@timezone} />
          </.fact>
          <.fact id="run-started-at" label={gettext("Started")}>
            <.local_time :if={@run.started_at} at={@run.started_at} timezone={@timezone} />
            <span :if={!@run.started_at} class="text-base-content/50">
              {if Run.final?(@run), do: gettext("never"), else: gettext("waiting")}
            </span>
          </.fact>
          <.fact id="run-finished-at" label={gettext("Finished")}>
            <.local_time :if={@run.finished_at} at={@run.finished_at} timezone={@timezone} />
            <span :if={!@run.finished_at} class="text-base-content/50">–</span>
          </.fact>
          <.fact id="run-duration" label={gettext("Duration")}>
            <span class="tabular-nums">{format_duration(run_duration(@run, @now))}</span>
          </.fact>
        </div>

        <.panel :if={@run.tests_passed != nil} id="run-tests" title={gettext("Tests")}>
          <:actions>
            <p id="run-tests-summary" class="flex flex-wrap items-center gap-x-2 text-xs tabular-nums">
              <span class="font-medium text-success">
                {gettext("%{count} passed", count: @run.tests_passed)}
              </span>
              <span class="text-base-content/30">·</span>
              <span class={[
                "font-medium",
                if(@run.tests_failed > 0, do: "text-error", else: "text-base-content/60")
              ]}>
                {gettext("%{count} failed", count: @run.tests_failed)}
              </span>
              <span class="text-base-content/30">·</span>
              <span class="text-base-content/60">
                {gettext("%{count} skipped", count: @run.tests_skipped)}
              </span>
              <span :if={@tests_duration_ms} class="text-base-content/30">·</span>
              <span :if={@tests_duration_ms} id="run-tests-duration" class="text-base-content/60">
                {format_ms(@tests_duration_ms)}
              </span>
            </p>
          </:actions>

          <ul id="test-failures" phx-update="stream" class="divide-y divide-base-300">
            <li
              id="test-failures-empty"
              class="hidden items-center gap-2 px-5 py-4 text-sm text-base-content/70 only:flex"
            >
              <.icon name="hero-check-circle" class="size-5 text-success" />
              {gettext("No test failed.")}
            </li>
            <.test_result_row
              :for={{id, result} <- @streams.test_failures}
              id={id}
              result={result}
            />
          </ul>

          <ul
            :if={@show_all_tests}
            id="test-others"
            phx-update="stream"
            class="divide-y divide-base-300 border-t border-base-300"
          >
            <.test_result_row :for={{id, result} <- @streams.test_others} id={id} result={result} />
          </ul>

          <div
            :if={!@show_all_tests and @run.tests_passed + @run.tests_skipped > 0}
            class="border-t border-base-300 px-3 py-2"
          >
            <.button id="show-all-tests" variant="ghost" size="sm" phx-click="show_all_tests">
              <.icon name="hero-chevron-down-mini" class="size-4" />
              {ngettext(
                "Show the test",
                "Show all %{count} tests",
                @run.tests_passed + @run.tests_failed + @run.tests_skipped
              )}
            </.button>
          </div>
        </.panel>

        <.panel id="run-output" title={gettext("Output")} class="overflow-hidden">
          <:actions>
            <span
              :if={@run.status == :running}
              id="run-output-live"
              class="inline-flex items-center gap-1.5 text-xs font-medium text-info"
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-full animate-ping rounded-full bg-current opacity-60"></span>
                <span class="relative inline-flex size-2 rounded-full bg-current"></span>
              </span>
              {gettext("live")}
            </span>
            <span
              :if={@line_count > 0 and !@run.logs_expired_at}
              id="run-output-count"
              class="text-xs text-base-content/60"
            >
              {ngettext("1 line", "%{count} lines", @line_count)}
            </span>
            <.button
              :if={@line_count > 0 and !@run.logs_expired_at}
              id="download-log"
              variant="ghost"
              size="sm"
              href={~p"/runs/#{@run.id}/log"}
              download
            >
              <.icon name="hero-arrow-down-tray-mini" class="size-4" /> {gettext("Download")}
            </.button>
          </:actions>

          <div class="relative bg-zinc-950 text-zinc-200">
            <p
              :if={!@run.logs_expired_at and (@first_sequence > 1 or @line_count > @max_lines)}
              id="run-output-earlier"
              class="border-b border-white/10 px-4 py-2 text-xs text-zinc-400"
            >
              {gettext("Earlier lines are not shown here.")}
              <.link
                href={~p"/runs/#{@run.id}/log"}
                class="font-medium text-zinc-200 underline underline-offset-2 hover:text-white"
              >
                {gettext("Download the full log")}
              </.link>
            </p>

            <div
              id="run-log"
              phx-hook=".LogFollow"
              data-jump="run-log-jump"
              class="max-h-[70vh] min-h-32 overflow-y-auto py-3 font-mono text-xs leading-5"
            >
              <ol id="log-lines" phx-update="stream" data-log-lines>
                <li
                  id="log-empty"
                  class="hidden px-4 py-6 text-center font-sans text-sm text-zinc-500 only:block"
                >
                  {cond do
                    @run.logs_expired_at ->
                      gettext("The log expired on %{date}.",
                        date: format_date(@run.logs_expired_at, @timezone)
                      )

                    Run.final?(@run) ->
                      gettext("The suite produced no output.")

                    @run.status == :running ->
                      gettext("Waiting for output…")

                    true ->
                      gettext("Output appears here once the suite starts.")
                  end}
                </li>
                <.log_line :for={{id, line} <- @streams.log_lines} id={id} line={line} />
              </ol>

              <p
                :if={@run.log_truncated and !@run.logs_expired_at}
                id="run-output-truncated"
                class="mx-2 mt-2 rounded-md border border-amber-400/30 bg-amber-400/10 px-3 py-2 font-sans text-xs text-amber-200"
              >
                {gettext(
                  "Log limit of %{limit} reached. Later output is shown while you watch, but not stored.",
                  limit: format_bytes(Runs.max_log_bytes())
                )}
              </p>
            </div>

            <div id="run-log-jump-container" phx-update="ignore" class="absolute right-4 bottom-4">
              <button
                id="run-log-jump"
                type="button"
                class="hidden items-center gap-1.5 rounded-full bg-zinc-100 px-3 py-1.5 text-xs font-medium text-zinc-900 shadow-lg transition hover:bg-white"
              >
                <.icon name="hero-arrow-down-mini" class="size-4" /> {gettext("Jump to latest")}
              </button>
            </div>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".LogFollow">
            // Keeps the log scrolled to the newest line while the reader is at the
            // bottom. Scrolling up pauses following; "Jump to latest" resumes it.
            export default {
              mounted() {
                this.list = this.el.querySelector("[data-log-lines]")
                this.jump = document.getElementById(this.el.dataset.jump)
                this.following = true
                this.scrollToEnd()

                this.el.addEventListener("scroll", () => {
                  const atEnd = this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight < 24
                  this.following = atEnd
                  this.jump.classList.toggle("hidden", atEnd)
                  this.jump.classList.toggle("flex", !atEnd)
                })

                this.jump.addEventListener("click", () => {
                  this.following = true
                  this.scrollToEnd()
                })

                this.observer = new MutationObserver(() => {
                  if (this.following) this.scrollToEnd()
                })
                this.observer.observe(this.list, { childList: true })
              },
              destroyed() {
                this.observer && this.observer.disconnect()
              },
              scrollToEnd() {
                this.el.scrollTop = this.el.scrollHeight
              }
            }
          </script>
        </.panel>

        <.panel
          :if={@artifact_count > 0 or @run.warnings != [] or @run.artifacts_expired_at}
          id="run-artifacts"
          title={gettext("Artifacts")}
        >
          <:actions>
            <span
              :if={@artifact_count > 0}
              id="run-artifacts-summary"
              class="text-xs text-base-content/60 tabular-nums"
            >
              {ngettext("1 file", "%{count} files", @artifact_count)} · {format_size(@artifact_bytes)}
            </span>
          </:actions>

          <p
            :if={@run.artifacts_expired_at}
            id="run-artifacts-expired"
            class="flex items-center gap-2 border-b border-base-300 px-5 py-3 text-sm text-base-content/70"
          >
            <.icon name="hero-archive-box-x-mark-mini" class="size-4 shrink-0 text-base-content/40" />
            {gettext("Artifacts expired on %{date}. The test results are kept.",
              date: format_date(@run.artifacts_expired_at, @timezone)
            )}
          </p>

          <ul
            :if={@run.warnings != []}
            id="run-warnings"
            class="space-y-1.5 border-b border-base-300 bg-warning/5 px-5 py-3 text-sm"
          >
            <li
              :for={{warning, index} <- Enum.with_index(@run.warnings)}
              id={"run-warning-#{index}"}
              class="flex items-start gap-2"
            >
              <.icon
                name="hero-exclamation-triangle-mini"
                class="mt-0.5 size-4 shrink-0 text-warning"
              />
              <span class="min-w-0 break-words">{warning}</span>
            </li>
          </ul>

          <div :if={@media_count > 0} class="border-b border-base-300 px-5 py-4">
            <div
              id="artifact-media"
              phx-update="stream"
              class="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-4"
            >
              <figure :for={{id, artifact} <- @streams.media} id={id} class="group min-w-0">
                <a
                  :if={artifact_kind(artifact) == :image}
                  href={artifact_url(@run.id, artifact.name)}
                  target="_blank"
                  rel="noopener"
                  class="block aspect-video overflow-hidden rounded-lg border border-base-300 bg-base-200"
                >
                  <img
                    src={artifact_url(@run.id, artifact.name)}
                    alt={artifact.name}
                    loading="lazy"
                    class="size-full object-cover object-top transition duration-200 group-hover:scale-[1.03]"
                  />
                </a>
                <video
                  :if={artifact_kind(artifact) == :video}
                  src={artifact_url(@run.id, artifact.name)}
                  controls
                  preload="none"
                  class="aspect-video w-full rounded-lg border border-base-300 bg-black"
                />
                <figcaption class="mt-1.5 truncate text-xs text-base-content/60" title={artifact.name}>
                  {artifact.name}
                </figcaption>
              </figure>
            </div>
            <p
              :if={@media_count > @max_media}
              id="artifact-media-more"
              class="mt-3 text-xs text-base-content/60"
            >
              {gettext("%{count} more images and videos are in the list below.",
                count: @media_count - @max_media
              )}
            </p>
          </div>

          <ul
            :if={@artifact_count > 0}
            id="artifact-tree"
            phx-update="stream"
            class="py-2 text-sm"
          >
            <li
              :for={{id, row} <- @streams.artifact_rows}
              id={id}
              data-kind={row.kind}
              class="flex items-center gap-2 py-1.5 pr-5 transition-colors hover:bg-base-200/40"
              style={"padding-left: #{1.25 + row.depth * 1.25}rem"}
            >
              <%= if row.kind == :dir do %>
                <.icon name="hero-folder-mini" class="size-4 shrink-0 text-base-content/40" />
                <span class="min-w-0 flex-1 truncate font-medium">{row.name}/</span>
                <.report_link :if={row.index} href={artifact_url(@run.id, row.index.name)} />
              <% else %>
                <.icon
                  name={artifact_icon(artifact_kind(row.artifact))}
                  class="size-4 shrink-0 text-base-content/40"
                />
                <a
                  href={artifact_url(@run.id, row.artifact.name)}
                  target="_blank"
                  rel="noopener"
                  class="min-w-0 flex-1 truncate transition-colors hover:text-primary"
                  title={row.artifact.name}
                >
                  {row.name}
                </a>
                <.report_link
                  :if={artifact_kind(row.artifact) == :html and row.name != "index.html"}
                  href={artifact_url(@run.id, row.artifact.name)}
                />
                <span class="shrink-0 text-xs text-base-content/50 tabular-nums">
                  {format_size(row.artifact.size_bytes)}
                </span>
              <% end %>
            </li>
          </ul>
        </.panel>

        <.panel id="run-execution" title={gettext("Execution")}>
          <dl class="divide-y divide-base-300 text-sm">
            <.detail label={gettext("Trigger")}>
              <span id="run-trigger" class="flex flex-wrap items-center gap-1.5">
                <%= if @schedule do %>
                  <.link
                    id="run-schedule"
                    navigate={
                      ~p"/projects/#{@run.test_definition.project.slug}/schedules/#{@schedule.id}/edit"
                    }
                    class="font-medium transition-colors hover:text-primary"
                  >
                    {trigger_label(@run.trigger)}
                    <span class="font-mono text-xs text-base-content/60">
                      {@schedule.cron_expression}
                    </span>
                  </.link>
                <% else %>
                  {trigger_label(@run.trigger)}
                <% end %>
                <span :if={triggered_by(@run)} id="run-triggered-by" class="text-base-content/60">
                  {gettext("by %{email}", email: triggered_by(@run))}
                </span>
                <span :if={triggered_via(@run)} id="run-triggered-via" class="text-base-content/60">
                  {gettext("via %{token}", token: triggered_via(@run))}
                </span>
              </span>
            </.detail>
            <%!-- The slot the run belongs to: after downtime or a queue wait, it differs
                  from when the run was queued or started. --%>
            <.detail :if={@run.scheduled_for} label={gettext("Scheduled for")}>
              <span id="run-scheduled-for">
                <.local_time
                  at={@run.scheduled_for}
                  timezone={(@schedule && @schedule.timezone) || @timezone}
                />
              </span>
            </.detail>
            <.detail label={gettext("Image")}>
              <span class="font-mono text-xs break-all">{@run.image}</span>
            </.detail>
            <.detail label={gettext("Digest")}>
              <span :if={@run.image_digest} id="run-digest" class="font-mono text-xs break-all">
                {@run.image_digest}
              </span>
              <span :if={!@run.image_digest} class="text-base-content/50">
                {if Run.final?(@run), do: gettext("not recorded"), else: gettext("after the pull")}
              </span>
            </.detail>
            <.detail label={gettext("Command")}>
              <code :if={@run.command != []} class="font-mono text-xs break-all whitespace-pre-wrap">{Enum.join(
                @run.command,
                " "
              )}</code>
              <span :if={@run.command == []} class="text-base-content/60">
                {gettext("the image's entrypoint")}
              </span>
            </.detail>
            <.detail :if={@delivery_count > 0} label={gettext("Notifications")}>
              <span id="run-notifications" phx-update="stream" class="flex flex-wrap gap-x-4 gap-y-1">
                <span
                  :for={{id, delivery} <- @streams.run_deliveries}
                  id={id}
                  class="inline-flex items-center gap-1.5"
                >
                  <span class="font-medium">{delivery.channel.name}</span>
                  <.delivery_status delivery={delivery} />
                </span>
              </span>
            </.detail>
            <.detail label={gettext("Exit code")}>
              <span :if={@run.exit_code != nil} id="run-exit-code" class="font-mono tabular-nums">
                {@run.exit_code}
              </span>
              <span :if={@run.exit_code == nil} class="text-base-content/50">–</span>
              <.badge :if={@run.oom_killed} tone={:warning} class="ml-2">
                {gettext("memory limit exceeded")}
              </.badge>
            </.detail>
          </dl>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl border border-base-300 bg-base-100 px-5 py-4">
      <p class="text-xs font-medium text-base-content/60">{@label}</p>
      <p class="mt-1 text-sm font-medium">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  attr :href, :string, required: true

  defp report_link(assigns) do
    ~H"""
    <a
      href={@href}
      target="_blank"
      rel="noopener"
      data-report
      class="inline-flex shrink-0 items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium text-primary transition-colors hover:bg-primary/10"
    >
      {gettext("Open report")}
      <.icon name="hero-arrow-top-right-on-square-mini" class="size-3.5" />
    </a>
    """
  end

  defp format_date(at, timezone),
    do: at |> DateTime.shift_zone!(timezone) |> Calendar.strftime("%-d %b %Y")

  defp artifact_icon(:image), do: "hero-photo-mini"
  defp artifact_icon(:video), do: "hero-film-mini"
  defp artifact_icon(:html), do: "hero-globe-alt-mini"
  defp artifact_icon(:file), do: "hero-document-mini"

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp detail(assigns) do
    ~H"""
    <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-3 px-5 py-3">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="min-w-0">{render_slot(@inner_block)}</dd>
    </div>
    """
  end
end
