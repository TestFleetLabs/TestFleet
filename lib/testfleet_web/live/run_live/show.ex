defmodule TestFleetWeb.RunLive.Show do
  @moduledoc """
  The run page (main spec sections 23 and 42): status, timing, and what was
  executed, updated live from `run:<id>`. Log output arrives with Milestone 4.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Runs
  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.Timezones

  # Lines loaded on mount, and the most kept in the page (Milestone 4, section 8).
  @history_lines 1_000
  @max_lines 2_000

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run!(id)

    # Subscribed before the history is loaded: a batch that overlaps it updates
    # the same lines (DOM id `log-<sequence>`) instead of repeating them.
    if connected?(socket), do: Runs.subscribe(run.id)

    lines = Runs.list_log_tail(run, @history_lines)

    {:ok,
     socket
     |> assign(:page_title, gettext("Run #%{id}", id: run.id))
     |> assign(:timezone, Timezones.default())
     |> assign(:ticking, false)
     |> assign(:cancelling, false)
     |> assign(:first_sequence, (List.first(lines) || %{sequence: 1}).sequence)
     |> assign(:line_count, max(run.last_log_sequence, length(lines)))
     |> assign(:max_lines, @max_lines)
     |> stream_configure(:log_lines, dom_id: &"log-#{&1.sequence}")
     |> stream(:log_lines, lines)
     |> assign_run(run)}
  end

  # While the run is active, the duration counts up once a second.
  defp assign_run(socket, run) do
    socket = assign(socket, run: run, now: DateTime.utc_now())

    counting? = run.started_at != nil and not Run.final?(run)

    if connected?(socket) and counting? and not socket.assigns.ticking do
      Process.send_after(self(), :tick, 1000)
      assign(socket, :ticking, true)
    else
      socket
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    :ok = Runs.cancel_run(socket.assigns.run)
    # An active run stops its container first (up to the grace period); the final
    # status arrives through `run:<id>`. A queued run is already cancelled.
    {:noreply, assign(socket, :cancelling, true)}
  end

  @impl true
  def handle_info(:tick, socket) do
    socket = assign(socket, :ticking, false)
    {:noreply, assign_run(socket, socket.assigns.run)}
  end

  def handle_info({event, %Run{id: id} = run}, %{assigns: %{run: %Run{id: id}}} = socket)
      when event in [:run_created, :run_updated, :run_finished] do
    {:noreply, assign_run(socket, run)}
  end

  def handle_info({:run_output, lines}, socket) do
    {:noreply,
     socket
     |> update(:line_count, &max(&1, List.last(lines).sequence))
     |> stream(:log_lines, lines, limit: -@max_lines)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
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
              :if={@cancelling and !Run.final?(@run)}
              id="cancelling-run"
              variant="danger"
              disabled
            >
              <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
              {gettext("Cancelling…")}
            </.button>
            <.button
              :if={!@cancelling and !Run.final?(@run)}
              id="cancel-run"
              variant="danger"
              phx-click="cancel"
              data-confirm={gettext("Cancel run #%{id}?", id: @run.id)}
            >
              <.icon name="hero-stop-mini" class="size-4" /> {gettext("Cancel run")}
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
            <span :if={@line_count > 0} id="run-output-count" class="text-xs text-base-content/60">
              {ngettext("1 line", "%{count} lines", @line_count)}
            </span>
            <.button
              :if={@line_count > 0}
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
              :if={@first_sequence > 1 or @line_count > @max_lines}
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
                    Run.final?(@run) -> gettext("The suite produced no output.")
                    @run.status == :running -> gettext("Waiting for output…")
                    true -> gettext("Output appears here once the suite starts.")
                  end}
                </li>
                <.log_line :for={{id, line} <- @streams.log_lines} id={id} line={line} />
              </ol>

              <p
                :if={@run.log_truncated}
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

        <.panel id="run-execution" title={gettext("Execution")}>
          <dl class="divide-y divide-base-300 text-sm">
            <.detail label={gettext("Trigger")}>{trigger_label(@run.trigger)}</.detail>
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
