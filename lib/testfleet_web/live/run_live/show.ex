defmodule TestFleetWeb.RunLive.Show do
  @moduledoc """
  The run page (main spec sections 23 and 42): status, timing, and what was
  executed, updated live from `run:<id>`. Log output arrives with Milestone 4.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Runs
  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.Timezones

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    run = Runs.get_run!(id)

    if connected?(socket), do: Runs.subscribe(run.id)

    {:ok,
     socket
     |> assign(:page_title, gettext("Run #%{id}", id: run.id))
     |> assign(:timezone, Timezones.default())
     |> assign(:ticking, false)
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
    {:noreply, socket}
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
              :if={!Run.final?(@run)}
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
