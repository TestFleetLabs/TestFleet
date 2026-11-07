defmodule TestFleetWeb.RunLive.Index do
  @moduledoc """
  The organization's runs, newest first, with filters and pages kept in the URL
  so a list can be shared:

      ?project=portal&environment=staging&status=failed&trigger=api
       &from=2026-11-01&to=2026-11-07&deployment=1.4.2&before=1842

  Unknown or invalid values are left out, as if not given. Pages are keyset pages
  by id (`before`, `after`), so runs created meanwhile never shift a page. The
  first page receives new runs live when they pass the filters; every page keeps
  the runs it shows current.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Runs}
  alias TestFleet.Schedules.Timezones
  alias TestFleetWeb.RunFeed

  @limit 50

  @statuses [
    {"queued", [:queued]},
    {"running", [:preparing, :running]},
    {"passed", [:passed]},
    {"failed", [:failed]},
    {"timeout", [:timeout]},
    {"cancelled", [:cancelled]},
    {"error", [:error]}
  ]
  @triggers %{"manual" => :manual, "schedule" => :schedule, "api" => :api}
  @fields ~w(project environment status trigger from to deployment)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Runs"))
     |> assign(:projects, Projects.list_projects(socket.assigns.current_scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {filters, values, project} = parse_filters(socket.assigns.current_scope, params)

    {:noreply,
     socket
     |> assign(
       filters: filters,
       values: values,
       filtered?: values != %{},
       form: to_form(Map.new(@fields, &{&1, Map.get(values, &1, "")})),
       environments: if(project, do: Environments.list_environments(project), else: []),
       page: page(params)
     )
     |> load_runs()}
  end

  @impl true
  def handle_event("filter", params, socket) do
    values =
      @fields
      |> Enum.map(&{&1, params[&1]})
      |> Enum.filter(fn {_field, value} -> is_binary(value) and String.trim(value) != "" end)
      |> Map.new(fn {field, value} -> {field, String.trim(value)} end)

    # Another project's environment would be left out anyway; say so in the URL.
    values =
      if values["project"] != socket.assigns.values["project"],
        do: Map.delete(values, "environment"),
        else: values

    {:noreply, push_patch(socket, to: list_path(socket.assigns.organization, values))}
  end

  @impl true
  def handle_info({:run_created, run} = message, socket) do
    if socket.assigns.page == :first and Runs.matches?(run, socket.assigns.filters) do
      socket = RunFeed.apply_event(socket, :runs, message, @limit)
      # A run pushed off this page is now on the next.
      {:noreply,
       assign(socket, :older?, socket.assigns.older? or length(shown_ids(socket)) == @limit)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, _run} = message, socket)
      when event in [:run_updated, :run_finished, :run_deleted] do
    {:noreply, RunFeed.apply_event(socket, :runs, message, @limit)}
  end

  ## Filters and pages

  defp parse_filters(scope, params) do
    project =
      slug_param(params, "project") && Projects.get_project_by_slug(scope, params["project"])

    environment =
      project && slug_param(params, "environment") &&
        Environments.get_environment_by_slug(project, params["environment"])

    statuses = List.keyfind(@statuses, params["status"], 0)
    trigger = @triggers[params["trigger"]]
    from = date_param(params, "from")
    to = date_param(params, "to")
    deployment = deployment_param(params)
    timezone = Timezones.default()

    filters =
      [
        project && {:project, project},
        environment && {:environment, environment},
        statuses && {:statuses, elem(statuses, 1)},
        trigger && {:trigger, trigger},
        from && {:queued_from, Runs.day_start(from, timezone)},
        to && {:queued_until, Runs.day_start(Date.add(to, 1), timezone)},
        deployment && {:deployment, deployment}
      ]
      |> Enum.filter(& &1)

    values =
      [
        project && {"project", project.slug},
        environment && {"environment", environment.slug},
        statuses && {"status", elem(statuses, 0)},
        trigger && {"trigger", params["trigger"]},
        from && {"from", Date.to_iso8601(from)},
        to && {"to", Date.to_iso8601(to)},
        deployment && {"deployment", deployment}
      ]
      |> Enum.filter(& &1)
      |> Map.new()

    {filters, values, project}
  end

  defp slug_param(params, key) do
    case params[key] do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> nil
    end
  end

  defp date_param(params, key) do
    with value when is_binary(value) <- params[key],
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _ -> nil
    end
  end

  defp deployment_param(params) do
    case params["deployment"] do
      text when is_binary(text) ->
        text = String.trim(text)
        if text != "" and String.length(text) <= 100, do: text

      _ ->
        nil
    end
  end

  defp page(params) do
    cond do
      id = id_param(params, "before") -> {:before, id}
      id = id_param(params, "after") -> {:after, id}
      true -> :first
    end
  end

  defp id_param(params, key) do
    with value when is_binary(value) <- params[key],
         {id, ""} when id > 0 <- Integer.parse(value) do
      id
    else
      _ -> nil
    end
  end

  # One more than a page tells whether there is another one.
  defp load_runs(socket) do
    scope = socket.assigns.current_scope
    filters = socket.assigns.filters

    {runs, older?, newer?} =
      case socket.assigns.page do
        :first ->
          runs = Runs.list_runs(scope, filters ++ [limit: @limit + 1])
          {Enum.take(runs, @limit), length(runs) > @limit, false}

        {:before, id} ->
          runs = Runs.list_runs(scope, filters ++ [before: id, limit: @limit + 1])
          {Enum.take(runs, @limit), length(runs) > @limit, true}

        {:after, id} ->
          runs =
            Runs.list_runs(scope, filters ++ [after: id, oldest_first: true, limit: @limit + 1])

          {runs |> Enum.take(@limit) |> Enum.reverse(), true, length(runs) > @limit}
      end

    socket
    |> assign(older?: older?, newer?: newer?)
    |> RunFeed.init(:runs, runs, reset: true)
  end

  defp shown_ids(socket), do: socket.assigns.run_feed_ids.runs

  defp list_path(organization, values), do: ~p"/#{organization}/runs?#{Enum.sort(values)}"

  defp status_options do
    [
      {gettext("Queued"), "queued"},
      {gettext("Running"), "running"},
      {gettext("Passed"), "passed"},
      {gettext("Failed"), "failed"},
      {gettext("Timeout"), "timeout"},
      {gettext("Cancelled"), "cancelled"},
      {gettext("Error"), "error"}
    ]
  end

  defp trigger_options,
    do: [
      {gettext("Manual"), "manual"},
      {gettext("Schedule"), "schedule"},
      {gettext("API"), "api"}
    ]

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns,
        older_path: assigns.older? && shown_ids_path(assigns, :older),
        newer_path: assigns.newer? && shown_ids_path(assigns, :newer)
      )

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:runs}>
      <div id="runs" class="space-y-6">
        <.page_header
          title={gettext("Runs")}
          description={gettext("Every execution of a test suite, newest first.")}
        />

        <.form
          for={@form}
          id="run-filters"
          phx-change="filter"
          phx-submit="filter"
          class="grid grid-cols-2 gap-3 rounded-xl border border-base-300 bg-base-100 p-4 sm:grid-cols-4 xl:grid-cols-7"
        >
          <.input
            field={@form[:project]}
            type="select"
            label={gettext("Project")}
            prompt={gettext("All projects")}
            options={Enum.map(@projects, &{&1.name, &1.slug})}
          />
          <.input
            field={@form[:environment]}
            type="select"
            label={gettext("Environment")}
            prompt={
              if(@environments == [],
                do: gettext("Choose a project"),
                else: gettext("All environments")
              )
            }
            options={Enum.map(@environments, &{&1.name, &1.slug})}
            disabled={@environments == []}
          />
          <.input
            field={@form[:status]}
            type="select"
            label={gettext("Status")}
            prompt={gettext("Any status")}
            options={status_options()}
          />
          <.input
            field={@form[:trigger]}
            type="select"
            label={gettext("Trigger")}
            prompt={gettext("Any trigger")}
            options={trigger_options()}
          />
          <.input field={@form[:from]} type="date" label={gettext("From")} />
          <.input field={@form[:to]} type="date" label={gettext("To")} />
          <.input
            field={@form[:deployment]}
            type="search"
            label={gettext("Deployment")}
            placeholder={gettext("Version or commit")}
            phx-debounce="300"
          />
        </.form>

        <div :if={@filtered?} id="run-filters-active" class="-mt-2 flex items-center gap-2 text-xs">
          <span class="text-base-content/60">{gettext("Filtered list")}</span>
          <.link
            id="run-filters-clear"
            patch={~p"/#{@organization}/runs"}
            class="inline-flex items-center gap-1 font-medium text-primary transition-colors hover:text-primary/80"
          >
            <.icon name="hero-x-mark-mini" class="size-3.5" /> {gettext("Clear filters")}
          </.link>
        </div>

        <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100">
          <ul id="run-list" phx-update="stream" class="divide-y divide-base-300">
            <li id="runs-empty" class="hidden only:block">
              <.empty_state
                :if={@filtered?}
                id="runs-empty-filtered"
                icon="hero-funnel"
                title={gettext("No runs match these filters")}
                compact
              >
                {gettext("Change or clear the filters to see more runs.")}
              </.empty_state>
              <.empty_state
                :if={!@filtered?}
                id="runs-empty-state"
                icon="hero-play-circle"
                title={gettext("No runs yet")}
                compact
              >
                {gettext(
                  "Runs appear here when a test definition is started manually, by a schedule, or through the API."
                )}
              </.empty_state>
            </li>
            <.run_row :for={{id, run} <- @streams.runs} id={id} run={run} />
          </ul>
        </section>

        <nav
          :if={@older_path || @newer_path}
          id="run-pages"
          aria-label={gettext("Pages")}
          class="flex items-center justify-between gap-3"
        >
          <.link
            :if={@newer_path}
            id="runs-newer"
            patch={@newer_path}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium transition-colors hover:border-primary/40 hover:text-primary"
          >
            <.icon name="hero-arrow-left-mini" class="size-4" /> {gettext("Newer")}
          </.link>
          <span :if={!@newer_path}></span>
          <.link
            :if={@older_path}
            id="runs-older"
            patch={@older_path}
            class="inline-flex items-center gap-1.5 rounded-lg border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium transition-colors hover:border-primary/40 hover:text-primary"
          >
            {gettext("Older")} <.icon name="hero-arrow-right-mini" class="size-4" />
          </.link>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  # From the runs shown now, so runs added or deleted live keep the pages exact.
  defp shown_ids_path(assigns, direction) do
    %{organization: organization, values: values} = assigns

    case {direction, assigns.run_feed_ids.runs} do
      # An empty page past the oldest run: back to the newest.
      {:newer, []} -> list_path(organization, values)
      {:older, []} -> nil
      {:older, ids} -> list_path(organization, Map.put(values, "before", List.last(ids)))
      {:newer, [first | _]} -> list_path(organization, Map.put(values, "after", first))
    end
  end
end
