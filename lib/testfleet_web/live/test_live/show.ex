defmodule TestFleetWeb.TestLive.Show do
  @moduledoc """
  A test across runs (spec sections 10 and 41): its state per environment, the
  outcomes of its latest runs, and its history.

  A test has no row of its own: its identity (`suite`, `classname`, `name`) is in
  the query string, `env` chooses an environment.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Results, Runs, TestDefinitions}
  alias TestFleet.Schedules.Timezones

  @page 50

  @impl true
  def mount(%{"slug" => slug, "id" => id} = params, _session, socket) do
    project = Projects.get_project_by_slug!(socket.assigns.current_scope, slug)
    test_definition = TestDefinitions.get_test_definition!(project, id)

    test = %{
      suite: params["suite"] || "",
      classname: params["classname"] || "",
      name: params["name"] || ""
    }

    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, test.name)
     |> assign(:project, project)
     |> assign(:test_definition, test_definition)
     |> assign(:test, test)
     |> assign(:environments, Environments.list_environments(project))
     |> assign(:timezone, Timezones.default())
     |> assign(:window_size, Results.window_size())
     |> stream_configure(:history, dom_id: &"history-#{&1.run_id}")
     |> assign_summaries()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selected = Enum.find(socket.assigns.environments, &(&1.slug == params["env"]))

    {:noreply,
     socket
     |> assign(:selected, selected)
     |> reset_history()}
  end

  # The environments that reported the test, in the project's order.
  defp assign_summaries(socket) do
    %{test_definition: test_definition, test: test, environments: environments} = socket.assigns

    by_environment =
      Map.new(Results.test_summary(test_definition, test), &{&1.environment_id, &1})

    summaries =
      for environment <- environments,
          summary = by_environment[environment.id],
          do: {environment, summary}

    assign(socket, :summaries, summaries)
  end

  defp reset_history(socket) do
    entries = history_page(socket, nil)

    socket
    |> assign_page(entries)
    |> stream(:history, Enum.take(entries, @page), reset: true)
  end

  defp history_page(socket, before) do
    %{test_definition: test_definition, test: test, selected: selected} = socket.assigns

    Results.test_history(test_definition, test,
      environment: selected,
      before: before,
      limit: @page + 1
    )
  end

  defp assign_page(socket, entries) do
    shown = Enum.take(entries, @page)

    assign(socket,
      history_more: length(entries) > @page,
      history_cursor: if(last = List.last(shown), do: last.run_id)
    )
  end

  @impl true
  def handle_event("more", _params, socket) do
    entries = history_page(socket, socket.assigns.history_cursor)

    {:noreply,
     socket
     |> assign_page(entries)
     |> stream(:history, Enum.take(entries, @page))}
  end

  @impl true
  def handle_info(
        {:run_finished, %{test_definition_id: id, tests_passed: passed} = run},
        %{assigns: %{test_definition: %{id: id}}} = socket
      )
      when passed != nil do
    socket = assign_summaries(socket)
    selected = socket.assigns.selected

    socket =
      with true <- selected == nil or selected.id == run.environment_id,
           [%{run_id: run_id} = entry] when run_id == run.id <-
             Results.test_history(socket.assigns.test_definition, socket.assigns.test,
               environment: selected,
               limit: 1
             ) do
        stream_insert(socket, :history, entry, at: 0)
      else
        _not_reported -> socket
      end

    {:noreply, socket}
  end

  def handle_info({event, _run}, socket)
      when event in [:run_created, :run_updated, :run_finished, :run_deleted],
      do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        location: test_location(assigns.test),
        selected_summary:
          assigns.selected &&
            Enum.find_value(assigns.summaries, fn {environment, summary} ->
              if environment.id == assigns.selected.id, do: summary
            end)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div id="test" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/#{@organization}/projects"}>{gettext("Projects")}</:crumb>
            <:crumb navigate={~p"/#{@organization}/projects/#{@project.slug}"}>
              {@project.name}
            </:crumb>
            <:crumb navigate={
              ~p"/#{@organization}/projects/#{@project.slug}/test-definitions/#{@test_definition.id}"
            }>
              {@test_definition.name}
            </:crumb>
            <:crumb>{gettext("Test")}</:crumb>
          </.breadcrumbs>

          <div class="border-b border-base-300 pb-6">
            <p
              :if={@location != ""}
              id="test-location"
              class="font-mono text-xs text-base-content/60"
            >
              {@location}
            </p>
            <h1 id="test-name" class="mt-1 text-2xl font-semibold tracking-tight break-words">
              {@test.name}
            </h1>
          </div>
        </div>

        <.empty_state
          :if={@summaries == []}
          id="test-no-results"
          icon="hero-beaker"
          title={gettext("No results for this test")}
        >
          {gettext(
            "No run of %{test_definition} reported it, or the runs that did were deleted.",
            test_definition: @test_definition.name
          )}
        </.empty_state>

        <div
          :if={@summaries != []}
          id="test-environments"
          class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3"
        >
          <.environment_card
            :for={{environment, summary} <- @summaries}
            environment={environment}
            summary={summary}
            selected={@selected && @selected.id == environment.id}
            patch={self_path(assigns, environment)}
            window_size={@window_size}
          />
        </div>

        <.panel
          :if={@selected_summary}
          id="test-outcomes"
          title={gettext("Latest runs in %{environment}", environment: @selected.name)}
        >
          <:actions>
            <span class="text-xs text-base-content/60">
              {gettext("oldest → newest")}
            </span>
          </:actions>
          <div class="px-5 py-4">
            <ol
              :if={@selected_summary.window != []}
              id="test-outcome-strip"
              class="flex flex-wrap items-end gap-1"
            >
              <li :for={entry <- @selected_summary.window} id={"outcome-#{entry.run_id}"}>
                <.link
                  navigate={~p"/#{@organization}/runs/#{entry.run_id}"}
                  data-outcome={entry.outcome}
                  data-mixed={to_string(entry.mixed)}
                  title={outcome_title(entry, @timezone)}
                  class={[
                    "block h-9 w-3 rounded-sm transition duration-150 hover:-translate-y-0.5 hover:opacity-80 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary sm:w-4",
                    outcome_cell(entry)
                  ]}
                >
                  <span class="sr-only">{outcome_title(entry, @timezone)}</span>
                </.link>
              </li>
            </ol>
            <p
              :if={@selected_summary.window == []}
              id="test-outcome-strip-empty"
              class="text-sm text-base-content/60"
            >
              {gettext("Not reported in the latest %{count} runs.", count: @window_size)}
            </p>
          </div>
        </.panel>

        <.panel :if={@summaries != []} id="test-history" title={gettext("History")}>
          <:actions>
            <nav
              id="history-environments"
              class="flex flex-wrap items-center rounded-lg bg-base-200 p-0.5 text-xs font-medium"
            >
              <.environment_tab
                id="history-tab-all"
                active={is_nil(@selected)}
                patch={self_path(assigns, nil)}
              >
                {gettext("All")}
              </.environment_tab>
              <.environment_tab
                :for={{environment, _summary} <- @summaries}
                id={"history-tab-#{environment.slug}"}
                active={@selected && @selected.id == environment.id}
                patch={self_path(assigns, environment)}
              >
                {environment.name}
              </.environment_tab>
            </nav>
          </:actions>

          <ul id="history" phx-update="stream" class="divide-y divide-base-300">
            <li id="history-empty" class="hidden px-5 py-4 text-sm text-base-content/60 only:block">
              {gettext("No results in this environment.")}
            </li>
            <.history_row
              :for={{id, entry} <- @streams.history}
              id={id}
              entry={entry}
              environments={@environments}
              organization={@organization}
              timezone={@timezone}
            />
          </ul>

          <div :if={@history_more} class="border-t border-base-300 px-3 py-2">
            <.button id="history-more" variant="ghost" size="sm" phx-click="more">
              <.icon name="hero-chevron-down-mini" class="size-4" /> {gettext("Load more")}
            </.button>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end

  attr :environment, :any, required: true
  attr :summary, :map, required: true
  attr :selected, :boolean, required: true
  attr :patch, :string, required: true
  attr :window_size, :integer, required: true

  defp environment_card(assigns) do
    ~H"""
    <.link
      id={"test-environment-#{@environment.slug}"}
      patch={@patch}
      aria-current={@selected && "true"}
      class={[
        "group block rounded-xl border bg-base-100 px-5 py-4 transition duration-150 hover:-translate-y-px hover:shadow-sm",
        if(@selected,
          do: "border-primary/60 ring-1 ring-primary/30",
          else: "border-base-300 hover:border-base-content/20"
        )
      ]}
    >
      <div class="flex items-center justify-between gap-3">
        <p class="truncate text-sm font-semibold">{@environment.name}</p>
        <.badge
          :if={@summary.flaky}
          tone={:warning}
          data-flaky
          title={gettext("Its outcome keeps changing on the same image")}
        >
          <.icon name="hero-arrows-right-left-mini" class="size-3.5" /> {gettext("Flaky")}
        </.badge>
      </div>

      <div class="mt-3 flex items-center gap-2">
        <.test_outcome
          id={"test-environment-#{@environment.slug}-latest"}
          outcome={@summary.latest.outcome}
          mixed={@summary.latest.mixed}
        />
      </div>

      <p
        id={"test-environment-#{@environment.slug}-streak"}
        class="mt-1 text-xs text-base-content/70"
      >
        {streak_text(@summary.streak)}
      </p>

      <dl class="mt-3 flex gap-5 border-t border-base-300 pt-3 text-xs">
        <div>
          <dt class="text-base-content/50">{gettext("Pass rate")}</dt>
          <dd
            id={"test-environment-#{@environment.slug}-pass-rate"}
            class="font-medium tabular-nums"
          >
            {if @summary.pass_rate, do: "#{round(@summary.pass_rate * 100)}%", else: "–"}
          </dd>
        </div>
        <div>
          <dt class="text-base-content/50">{gettext("Flips")}</dt>
          <dd id={"test-environment-#{@environment.slug}-flips"} class="font-medium tabular-nums">
            {@summary.flips}
          </dd>
        </div>
        <div class="min-w-0">
          <dt class="text-base-content/50">{gettext("Window")}</dt>
          <dd class="truncate font-medium text-base-content/70">
            {gettext("last %{count} runs", count: @window_size)}
          </dd>
        </div>
      </dl>
    </.link>
    """
  end

  attr :id, :string, required: true
  attr :active, :boolean, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp environment_tab(assigns) do
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

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :environments, :list, required: true
  attr :organization, :any, required: true
  attr :timezone, :string, required: true

  defp history_row(assigns) do
    assigns =
      assign(
        assigns,
        :environment,
        Enum.find(assigns.environments, &(&1.id == assigns.entry.environment_id))
      )

    ~H"""
    <li id={@id} data-outcome={@entry.outcome}>
      <.link
        navigate={~p"/#{@organization}/runs/#{@entry.run_id}"}
        class="group grid grid-cols-[minmax(0,1fr)_auto] items-start gap-x-4 gap-y-1 px-5 py-3 transition-colors hover:bg-base-200/40"
      >
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
            <.test_outcome outcome={@entry.outcome} mixed={@entry.mixed} />
            <span class="text-sm font-medium text-base-content/80 tabular-nums">
              #{@entry.run_id}
            </span>
            <span :if={@environment} class="text-xs text-base-content/60">
              {@environment.name}
            </span>
            <span :if={@entry.cases > 1} class="text-xs text-base-content/50">
              {ngettext("1 case", "%{count} cases", @entry.cases)}
            </span>
          </div>
          <p
            :if={@entry.failure_message}
            data-failure-message
            class="mt-1 line-clamp-2 font-mono text-xs break-words text-error/90"
          >
            {@entry.failure_message}
          </p>
        </div>
        <div class="flex items-center gap-3 text-right text-xs text-base-content/60">
          <div>
            <.local_time :if={@entry.finished_at} at={@entry.finished_at} timezone={@timezone} />
            <p class="flex items-center justify-end gap-2 tabular-nums">
              <span :if={@entry.duration_ms}>{format_ms(@entry.duration_ms)}</span>
              <span
                :if={@entry.image_digest}
                class="hidden font-mono text-[0.7rem] text-base-content/40 sm:inline"
                title={@entry.image_digest}
              >
                {short_digest(@entry.image_digest)}
              </span>
            </p>
          </div>
          <.icon
            name="hero-chevron-right-mini"
            class="size-4 shrink-0 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-primary"
          />
        </div>
      </.link>
    </li>
    """
  end

  # This page with `env` set to the environment's slug, or without it.
  defp self_path(assigns, environment) do
    %{organization: organization, project: project, test_definition: test_definition} = assigns

    query = [
      suite: assigns.test.suite,
      classname: assigns.test.classname,
      name: assigns.test.name
    ]

    query = if environment, do: query ++ [env: environment.slug], else: query

    ~p"/#{organization}/projects/#{project.slug}/test-definitions/#{test_definition.id}/tests?#{query}"
  end

  defp streak_text(nil), do: gettext("Only skipped so far")

  defp streak_text(%{outcome: :passed, count: count}),
    do: ngettext("Passing for 1 run", "Passing for %{count} runs", count)

  defp streak_text(%{outcome: :red, count: count, since_run_id: since}),
    do: ngettext("Failing for 1 run", "Failing for %{count} runs, since #%{id}", count, id: since)

  defp outcome_cell(%{mixed: true}),
    do:
      "bg-[repeating-linear-gradient(135deg,var(--color-error)_0_3px,var(--color-success)_3px_6px)]"

  defp outcome_cell(%{outcome: :passed}), do: "bg-success"
  defp outcome_cell(%{outcome: :failed}), do: "bg-error"
  defp outcome_cell(%{outcome: :error}), do: "bg-warning"
  defp outcome_cell(%{outcome: :skipped}), do: "bg-base-300"

  defp outcome_title(entry, timezone) do
    [
      "##{entry.run_id}",
      test_outcome_label(entry.outcome) <>
        if(entry.mixed, do: " (#{gettext("passed on retry")})", else: ""),
      entry.finished_at &&
        entry.finished_at
        |> DateTime.shift_zone!(timezone)
        |> Calendar.strftime("%-d %b %Y, %H:%M"),
      entry.duration_ms && format_ms(entry.duration_ms)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp short_digest("sha256:" <> hex), do: String.slice(hex, 0, 12)
  defp short_digest(digest), do: digest
end
