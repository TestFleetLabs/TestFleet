defmodule TestFleetWeb.RunLive.Show do
  @moduledoc """
  The run page: status, timing, what was executed, the log, results, and
  artifacts, updated live from `run:<id>`.
  """
  use TestFleetWeb, :live_view

  import TestFleetWeb.NotificationComponents, only: [delivery_status: 1]

  alias TestFleet.{Artifacts, Notifications, Results, Runs, Schedules}
  alias TestFleet.Accounts.Scope
  alias TestFleet.Results.Comparison
  alias TestFleet.Runs.{Deployment, Run}
  alias TestFleet.Schedules.Timezones

  # Lines loaded on mount, and the most kept in the page.
  @history_lines 1_000
  @max_lines 2_000
  # Images and videos previewed above the artifact list; all are in the list.
  @max_media 24
  # Failure streaks and flaky tests, loaded after the failures.
  @no_notes %{streaks: %{}, flaky: MapSet.new()}

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    run = Runs.get_run!(socket.assigns.current_scope, id)

    # Subscribed before the history is loaded: a batch that overlaps it updates
    # the same lines (DOM id `log-<sequence>`) instead of repeating them.
    if connected?(socket) do
      Runs.subscribe(run.id)
      Notifications.subscribe_deliveries(socket.assigns.current_scope)
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
       max_media: @max_media,
       # The Changes panel's baseline: "previous", "last_passed", or a run id.
       compare: params["compare"] || "previous",
       compare_form: to_form(%{"run" => ""}),
       comparison: nil
     )
     |> stream(:test_failures, [])
     |> stream(:test_others, [])
     |> stream(:media, [])
     |> stream(:artifact_rows, [])
     # Notifications this run caused
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
        if(junit?,
          do: run |> Results.list_test_results(only: :failures) |> annotate(@no_notes),
          else: []
        ),
        reset: true
      )
      |> stream(:media, Enum.take(media, @max_media), reset: true)
      |> stream(:artifact_rows, artifact_tree(artifacts), reset: true)
      |> load_failure_notes()
      |> load_comparison()
    else
      socket
    end
  end

  defp maybe_load_results(socket), do: socket

  # The failures with their streak and flaky flag, as the stream's items.
  defp annotate(failures, notes) do
    Enum.map(failures, fn result ->
      test = Results.test_of(result)

      %{
        id: result.id,
        result: result,
        streak: notes.streaks[test],
        flaky: MapSet.member?(notes.flaky, test)
      }
    end)
  end

  # Loaded after the failures, so the panel never waits for them (spec section 41).
  defp load_failure_notes(socket) do
    run = socket.assigns.run

    if connected?(socket) and is_integer(run.tests_failed) and run.tests_failed > 0 do
      start_async(socket, :failure_notes, fn ->
        flaky =
          run.test_definition
          |> Results.flaky_tests(run.environment, up_to: run.id, limit: nil)
          |> MapSet.new(& &1.test)

        %{streaks: Results.failure_streaks(run), flaky: flaky}
      end)
    else
      socket
    end
  end

  defp load_comparison(socket) do
    %{run: run, compare: compare, current_scope: scope} = socket.assigns

    if connected?(socket) and Run.final?(run) and run.tests_passed != nil do
      assign_async(socket, :comparison, fn ->
        {:ok, %{comparison: build_comparison(scope, run, compare)}}
      end)
    else
      socket
    end
  end

  defp build_comparison(scope, run, compare) do
    {baseline, mode, problem} = resolve_baseline(scope, run, compare)
    %{mode: mode, problem: problem, comparison: baseline && Results.compare(run, baseline)}
  end

  # A run that cannot be compared falls back to the previous run, with the reason.
  defp resolve_baseline(_scope, run, "previous"),
    do: {Runs.baseline(run, :previous), :previous, nil}

  defp resolve_baseline(_scope, run, "last_passed"),
    do: {Runs.baseline(run, :last_passed), :last_passed, nil}

  defp resolve_baseline(scope, run, compare) do
    with {id, ""} <- Integer.parse(compare),
         %Run{} = candidate <- Runs.get_run(scope, id),
         :ok <- Runs.comparable(run, candidate) do
      {candidate, :run, nil}
    else
      {:error, reason} -> {Runs.baseline(run, :previous), :previous, {compare, reason}}
      _not_found -> {Runs.baseline(run, :previous), :previous, {compare, :not_found}}
    end
  end

  @impl true
  def handle_async(:failure_notes, {:ok, notes}, socket) do
    failures = Results.list_test_results(socket.assigns.run, only: :failures)

    {:noreply, stream(socket, :test_failures, annotate(failures, notes), reset: true)}
  end

  # The badges are extras: without them, the failures stay as they are.
  def handle_async(:failure_notes, {:exit, _reason}, socket), do: {:noreply, socket}

  @impl true
  def handle_params(params, _uri, socket) do
    compare = params["compare"] || "previous"

    if compare == socket.assigns.compare,
      do: {:noreply, socket},
      else: {:noreply, socket |> assign(:compare, compare) |> load_comparison()}
  end

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

  def handle_event("hide_tests", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_all_tests, false)
     |> stream(:test_others, [], reset: true)}
  end

  def handle_event("compare", %{"run" => number}, socket) do
    compare =
      case number |> String.trim() |> String.trim_leading("#") do
        "" -> "previous"
        number -> number
      end

    path = ~p"/#{socket.assigns.organization}/runs/#{socket.assigns.run.id}?#{[compare: compare]}"
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("delete", _params, socket) do
    if Scope.admin?(socket.assigns.current_scope) do
      case Runs.delete_run(socket.assigns.run) do
        {:error, :not_final} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Only a finished run can be deleted. Cancel it first.")
           )}

        # Deleted meanwhile, too.
        _deleted ->
          {:noreply, leave_deleted(socket)}
      end
    else
      {:noreply, put_flash(socket, :error, gettext("Only admins can delete runs."))}
    end
  end

  def handle_event("cancel", _params, socket) do
    :ok = Runs.cancel_run(socket.assigns.run)
    # A queued run is cancelled now. An active one records the request (shown as
    # "Cancelling…", also after a reload) and stops its container first, up to the
    # grace period; the final status arrives through `run:<id>`.
    {:noreply,
     assign_run(socket, Runs.get_run!(socket.assigns.current_scope, socket.assigns.run.id))}
  end

  defp leave_deleted(socket) do
    socket
    |> put_flash(:info, gettext("Run #%{id} deleted.", id: socket.assigns.run.id))
    |> push_navigate(to: ~p"/#{socket.assigns.organization}/runs")
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

  def handle_info({:run_deleted, %Run{id: id}}, %{assigns: %{run: %Run{id: id}}} = socket),
    do: {:noreply, leave_deleted(socket)}

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
            <:crumb navigate={~p"/#{@organization}/runs"}>{gettext("Runs")}</:crumb>
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
                    ~p"/#{@organization}/projects/#{@run.test_definition.project.slug}/test-definitions/#{@run.test_definition.id}"
                  }
                  class="font-medium text-base-content/80 transition-colors hover:text-primary"
                >
                  {@run.test_definition.name}
                </.link>
                <.icon name="hero-arrow-right-mini" class="size-3.5 text-base-content/40" />
                <.link
                  id="run-environment"
                  navigate={
                    ~p"/#{@organization}/projects/#{@run.test_definition.project.slug}/environments/#{@run.environment.slug}"
                  }
                  class="font-medium text-base-content/80 transition-colors hover:text-primary"
                >
                  {@run.environment.name}
                </.link>
                <span>·</span>
                <.link
                  navigate={~p"/#{@organization}/projects/#{@run.test_definition.project.slug}"}
                  class="transition-colors hover:text-base-content"
                >
                  {@run.test_definition.project.name}
                </.link>
              </p>
              <.deployment :if={@run.deployment} id="run-deployment" deployment={@run.deployment} />
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
            <div :if={Run.final?(@run)} class="flex flex-wrap items-center gap-2">
              <.button
                :if={Scope.admin?(@current_scope)}
                id="delete-run"
                variant="danger"
                phx-click="delete"
                data-confirm={
                  gettext(
                    "Delete run #%{id} with its log, test results, and artifacts? This cannot be undone.",
                    id: @run.id
                  )
                }
              >
                <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
              </.button>
              <.button
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

        <.panel :if={@comparison} id="run-changes" title={gettext("Changes")}>
          <:actions>
            <nav
              id="compare-modes"
              aria-label={gettext("Compare with")}
              class="flex items-center rounded-lg bg-base-200 p-0.5 text-xs font-medium"
            >
              <.compare_mode
                id="compare-previous"
                active={@compare == "previous"}
                patch={~p"/#{@organization}/runs/#{@run.id}?compare=previous"}
              >
                {gettext("Previous run")}
              </.compare_mode>
              <.compare_mode
                id="compare-last-passed"
                active={@compare == "last_passed"}
                patch={~p"/#{@organization}/runs/#{@run.id}?compare=last_passed"}
              >
                {gettext("Last passed")}
              </.compare_mode>
            </nav>
            <.form
              for={@compare_form}
              id="compare-form"
              phx-submit="compare"
              class="hidden items-center sm:flex"
            >
              <label for="compare-run" class="sr-only">{gettext("Compare with run number")}</label>
              <input
                id="compare-run"
                name={@compare_form[:run].name}
                value={@compare_form[:run].value}
                type="text"
                inputmode="numeric"
                placeholder={gettext("Run #")}
                class="w-20 rounded-lg border border-base-300 bg-base-100 px-2 py-1 text-xs tabular-nums transition-colors placeholder:text-base-content/40 focus:border-primary focus:outline-none"
              />
            </.form>
          </:actions>

          <.async_result :let={result} assign={@comparison}>
            <:loading>
              <p
                id="run-changes-loading"
                class="flex items-center gap-2 px-5 py-4 text-sm text-base-content/60"
              >
                <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
                {gettext("Comparing…")}
              </p>
            </:loading>
            <:failed :let={_reason}>
              <p id="run-changes-failed" class="px-5 py-4 text-sm text-base-content/60">
                {gettext("The comparison could not be loaded. Reload the page to try again.")}
              </p>
            </:failed>

            <p
              :if={result.problem}
              id="run-changes-problem"
              class="flex items-center gap-2 border-b border-base-300 bg-warning/5 px-5 py-3 text-sm text-base-content/70"
            >
              <.icon name="hero-exclamation-triangle-mini" class="size-4 shrink-0 text-warning" />
              {cannot_compare(result.problem)}
            </p>

            <.empty_state
              :if={!result.comparison}
              id="run-changes-none"
              icon="hero-arrows-right-left"
              title={
                if(result.mode == :last_passed,
                  do: gettext("No earlier run passed"),
                  else: gettext("No earlier run to compare with")
                )
              }
              compact
            >
              {gettext("Runs of this test definition in this environment with JUnit appear here.")}
            </.empty_state>

            <.changes
              :if={result.comparison}
              comparison={result.comparison}
              organization={@organization}
              timezone={@timezone}
            />
          </.async_result>
        </.panel>

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
              :for={{id, failure} <- @streams.test_failures}
              id={id}
              result={failure.result}
              href={run_test_path(@organization, @run, failure.result)}
              streak={failure.streak}
              flaky={failure.flaky}
            />
          </ul>

          <ul
            :if={@show_all_tests}
            id="test-others"
            phx-update="stream"
            class="divide-y divide-base-300 border-t border-base-300"
          >
            <.test_result_row
              :for={{id, result} <- @streams.test_others}
              id={id}
              result={result}
              href={run_test_path(@organization, @run, result)}
            />
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

          <div :if={@show_all_tests} class="border-t border-base-300 px-3 py-2">
            <.button id="hide-tests" variant="ghost" size="sm" phx-click="hide_tests">
              <.icon name="hero-chevron-up-mini" class="size-4" />
              {gettext("Hide passed and skipped tests")}
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
              href={~p"/#{@organization}/runs/#{@run.id}/log"}
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
                href={~p"/#{@organization}/runs/#{@run.id}/log"}
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
            <.button
              :if={@artifact_count > 0}
              id="download-artifacts"
              variant="ghost"
              size="sm"
              href={~p"/#{@organization}/runs/#{@run.id}/artifacts.zip"}
              download
            >
              <.icon name="hero-arrow-down-tray-mini" class="size-4" /> {gettext("Download")}
            </.button>
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
                  href={artifact_url(@run, artifact.name)}
                  target="_blank"
                  rel="noopener"
                  class="block aspect-video overflow-hidden rounded-lg border border-base-300 bg-base-200"
                >
                  <img
                    src={artifact_url(@run, artifact.name)}
                    alt={artifact.name}
                    loading="lazy"
                    class="size-full object-cover object-top transition duration-200 group-hover:scale-[1.03]"
                  />
                </a>
                <video
                  :if={artifact_kind(artifact) == :video}
                  src={artifact_url(@run, artifact.name)}
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
                <.report_link :if={row.index} href={artifact_url(@run, row.index.name)} />
              <% else %>
                <.icon
                  name={artifact_icon(artifact_kind(row.artifact))}
                  class="size-4 shrink-0 text-base-content/40"
                />
                <a
                  href={artifact_url(@run, row.artifact.name)}
                  target="_blank"
                  rel="noopener"
                  class="min-w-0 flex-1 truncate transition-colors hover:text-primary"
                  title={row.artifact.name}
                >
                  {row.name}
                </a>
                <.report_link
                  :if={artifact_kind(row.artifact) == :html and row.name != "index.html"}
                  href={artifact_url(@run, row.artifact.name)}
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
                      ~p"/#{@organization}/projects/#{@run.test_definition.project.slug}/schedules/#{@schedule.id}/edit"
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

  attr :id, :string, required: true
  attr :active, :boolean, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp compare_mode(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={@patch}
      aria-current={@active && "true"}
      class={[
        "rounded-md px-2.5 py-1 transition-colors",
        if(@active,
          do: "bg-base-100 text-base-content shadow-sm",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :comparison, Comparison, required: true
  attr :organization, :any, required: true
  attr :timezone, :string, required: true

  # The baseline, what differs between the two runs, and the tests by group.
  defp changes(assigns) do
    %{run: run, baseline: baseline} = assigns.comparison

    assigns =
      assign(assigns,
        run: run,
        baseline: baseline,
        image: image_change(run, baseline),
        deployment: deployment_change(run, baseline),
        duration: duration_change(run, baseline)
      )

    ~H"""
    <div class="space-y-2 border-b border-base-300 px-5 py-4">
      <p id="run-changes-baseline" class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
        <span class="text-base-content/60">{gettext("Compared with")}</span>
        <.link
          id="run-changes-baseline-link"
          navigate={~p"/#{@organization}/runs/#{@baseline.id}"}
          class="font-semibold tabular-nums transition-colors hover:text-primary"
        >
          #{@baseline.id}
        </.link>
        <.run_status status={@baseline.status} />
        <span class="text-xs text-base-content/60">
          <.local_time at={@baseline.finished_at} timezone={@timezone} />
        </span>
        <.badge
          :if={@baseline.environment_id != @run.environment_id}
          id="run-changes-environment"
          tone={:primary}
        >
          <.icon name="hero-globe-alt-mini" class="size-3.5" /> {@baseline.environment.name}
        </.badge>
      </p>

      <ul id="run-changes-facts" class="flex flex-wrap gap-x-5 gap-y-1 text-xs text-base-content/70">
        <li
          id="run-changes-image"
          data-changed={to_string(@image != :unchanged)}
          class="inline-flex items-center gap-1.5"
        >
          <%= case @image do %>
            <% :unchanged -> %>
              <.icon name="hero-check-mini" class="size-4 text-success" />
              {gettext("Image unchanged")}
            <% {:changed, from, to} -> %>
              <.icon name="hero-arrow-path-rounded-square-mini" class="size-4 text-info" />
              {gettext("Image changed")}
              <span class="font-mono text-[0.7rem] text-base-content/60">{from} → {to}</span>
          <% end %>
        </li>
        <li
          :if={@deployment}
          id="run-changes-deployment"
          data-changed={to_string(match?({:changed, _, _}, @deployment))}
          class="inline-flex items-center gap-1.5"
        >
          <%= case @deployment do %>
            <% {:unchanged, label} -> %>
              <.icon name="hero-rocket-launch-mini" class="size-4 text-base-content/40" />
              {gettext("Same deployment")}
              <span class="font-mono text-[0.7rem] text-base-content/60">{label}</span>
            <% {:changed, from, to} -> %>
              <.icon name="hero-rocket-launch-mini" class="size-4 text-info" />
              {gettext("Deployment")}
              <span class="font-mono text-[0.7rem] text-base-content/60">{from} → {to}</span>
          <% end %>
        </li>
        <li
          :if={@run.command != @baseline.command}
          id="run-changes-command"
          class="inline-flex items-center gap-1.5"
        >
          <.icon name="hero-command-line-mini" class="size-4 text-info" />
          {gettext("Command changed")}
        </li>
        <li :if={@duration} id="run-changes-duration" class="tabular-nums">
          {gettext("Duration")} {@duration}
        </li>
        <li id="run-changes-counts" class="tabular-nums">
          {gettext("%{from} → %{to} passed", from: @baseline.tests_passed, to: @run.tests_passed)}
          <span class="text-base-content/30">·</span>
          {gettext("%{from} → %{to} failed", from: @baseline.tests_failed, to: @run.tests_failed)}
        </li>
      </ul>
    </div>

    <ul id="run-changes-summary" class="flex flex-wrap gap-2 border-b border-base-300 px-5 py-3">
      <li
        :for={group <- Comparison.groups()}
        data-group={group}
        class={[
          "inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-xs font-medium tabular-nums",
          group_tone(group, Map.fetch!(@comparison, group).total)
        ]}
      >
        <span class="font-semibold">{Map.fetch!(@comparison, group).total}</span>
        {group_label(group)}
      </li>
    </ul>

    <div id="run-changes-groups">
      <.change_group
        :for={group <- Comparison.groups()}
        id={"run-changes-#{group}"}
        title={group_label(group)}
        group={Map.fetch!(@comparison, group)}
        open={group in [:new_failures, :fixed]}
        messages={group in [:new_failures, :still_failing]}
        organization={@organization}
        run={@run}
      />
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :group, :map, required: true
  attr :open, :boolean, required: true
  attr :messages, :boolean, required: true
  attr :organization, :any, required: true
  attr :run, Run, required: true

  defp change_group(assigns) do
    ~H"""
    <section :if={@group.total > 0} id={@id} class="border-b border-base-300 last:border-b-0">
      <details open={@open} class="group/changes">
        <summary class="flex cursor-pointer list-none items-center gap-2 px-5 py-2.5 text-xs font-semibold transition-colors hover:bg-base-200/40">
          <.icon
            name="hero-chevron-right-mini"
            class="size-4 text-base-content/50 transition-transform group-open/changes:rotate-90"
          />
          {@title}
          <span class="font-medium text-base-content/50 tabular-nums">{@group.total}</span>
        </summary>
        <ul class="pb-2">
          <li
            :for={test <- @group.tests}
            data-test={test.name}
            class="py-1.5 pr-5 pl-11 transition-colors hover:bg-base-200/30"
          >
            <div class="flex flex-wrap items-center gap-x-2.5 gap-y-0.5">
              <.test_outcome outcome={test.outcome} />
              <.link
                navigate={run_test_path(@organization, @run, test)}
                class="min-w-0 text-sm font-medium break-words transition-colors hover:text-primary"
              >
                {test.name}
              </.link>
              <span :if={test_location(test) != ""} class="truncate text-xs text-base-content/50">
                {test_location(test)}
              </span>
            </div>
            <p
              :if={@messages && test.failure_message}
              class="mt-0.5 line-clamp-2 font-mono text-xs text-error/90"
            >
              {test.failure_message}
            </p>
          </li>
        </ul>
        <p
          :if={@group.total > length(@group.tests)}
          class="px-5 pb-3 pl-11 text-xs text-base-content/60"
        >
          {gettext("and %{count} more", count: @group.total - length(@group.tests))}
        </p>
      </details>
    </section>
    """
  end

  defp group_label(:new_failures), do: gettext("New failures")
  defp group_label(:fixed), do: gettext("Fixed")
  defp group_label(:still_failing), do: gettext("Still failing")
  defp group_label(:added), do: gettext("Added")
  defp group_label(:removed), do: gettext("Removed")

  defp group_tone(_group, 0), do: "bg-base-200/60 text-base-content/50"
  defp group_tone(:new_failures, _total), do: "bg-error/10 text-error"
  defp group_tone(:fixed, _total), do: "bg-success/15 text-success"
  defp group_tone(:still_failing, _total), do: "bg-error/5 text-error/80"
  defp group_tone(_group, _total), do: "bg-base-200 text-base-content/70"

  defp cannot_compare({compare, reason}) do
    gettext("Run #%{id} cannot be compared: %{reason}. Showing the previous run instead.",
      id: compare,
      reason: not_comparable_reason(reason)
    )
  end

  defp not_comparable_reason(:not_found), do: gettext("there is no such run")
  defp not_comparable_reason(:same_run), do: gettext("it is this run")

  defp not_comparable_reason(:other_test_definition),
    do: gettext("it belongs to another test definition")

  defp not_comparable_reason(:not_final), do: gettext("it has not finished")
  defp not_comparable_reason(:no_junit), do: gettext("it has no JUnit results")

  # The image a run executed, by digest when it was recorded.
  defp image_change(run, baseline) do
    if run.image == baseline.image and run.image_digest == baseline.image_digest,
      do: :unchanged,
      else: {:changed, image_label(baseline), image_label(run)}
  end

  defp image_label(%Run{image_digest: "sha256:" <> hex}),
    do: "sha256:" <> String.slice(hex, 0, 12)

  defp image_label(%Run{image_digest: nil, image: image}), do: image
  defp image_label(%Run{image_digest: digest}), do: digest

  # Shown when either run names its deployment; a run without one reads "–".
  defp deployment_change(run, baseline) do
    case {Deployment.label(baseline.deployment), Deployment.label(run.deployment)} do
      {nil, nil} -> nil
      {same, same} -> {:unchanged, same}
      {from, to} -> {:changed, from || "–", to || "–"}
    end
  end

  defp duration_change(run, baseline) do
    with now when is_integer(now) <- run_duration(run, run.finished_at),
         before when is_integer(before) <- run_duration(baseline, baseline.finished_at) do
      delta = now - before
      sign = if delta < 0, do: "−", else: "+"
      sign <> format_duration(abs(delta))
    end
  end

  defp run_test_path(organization, run, test),
    do: test_path(organization, run.test_definition.project.slug, run.test_definition_id, test)

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
