defmodule TestFleetWeb.TestDefinitionLive.Show do
  @moduledoc """
  A test definition: its settings, "Run now" per environment, and its recent runs.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Runs, TestDefinitions}

  @recent_runs 20

  @impl true
  def mount(%{"slug" => slug, "id" => id}, _session, socket) do
    project = Projects.get_project_by_slug!(slug)
    test_definition = TestDefinitions.get_test_definition!(project, id)

    if connected?(socket), do: Runs.subscribe()

    runs = Runs.list_runs(test_definition: test_definition, limit: @recent_runs)

    {:ok,
     socket
     |> assign(:page_title, test_definition.name)
     |> assign(:project, project)
     |> assign(:test_definition, test_definition)
     |> assign(:environments, Environments.list_environments(project))
     |> assign(:oldest_run_id, runs |> List.last() |> then(&(&1 && &1.id)))
     |> stream(:runs, runs)}
  end

  @impl true
  def handle_event("run", %{"environment" => environment_id}, socket) do
    environment = Enum.find(socket.assigns.environments, &(to_string(&1.id) == environment_id))

    case environment && Runs.create_manual_run(socket.assigns.test_definition, environment) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/runs/#{run.id}")}

      {:error, :test_definition_disabled} ->
        {:noreply,
         put_flash(socket, :error, gettext("This test definition is disabled and cannot run."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("This environment no longer exists."))}
    end
  end

  @impl true
  def handle_info({event, run}, socket)
      when event in [:run_created, :run_updated, :run_finished] do
    %{test_definition: test_definition, oldest_run_id: oldest_run_id} = socket.assigns

    socket =
      cond do
        run.test_definition_id != test_definition.id ->
          socket

        event == :run_created ->
          socket
          |> assign(:oldest_run_id, oldest_run_id || run.id)
          |> stream_insert(:runs, run, at: 0, limit: @recent_runs)

        # Updates of runs older than the list would otherwise be appended to it.
        oldest_run_id && run.id >= oldest_run_id ->
          stream_insert(socket, :runs, run)

        true ->
          socket
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <div id="test-definition" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/projects"}>{gettext("Projects")}</:crumb>
            <:crumb navigate={~p"/projects/#{@project.slug}"}>{@project.name}</:crumb>
            <:crumb>{@test_definition.name}</:crumb>
          </.breadcrumbs>

          <.page_header title={@test_definition.name} description={@test_definition.description}>
            <:actions>
              <.badge :if={!@test_definition.enabled} tone={:warning}>{gettext("disabled")}</.badge>
              <.button
                id="edit-test-definition"
                navigate={~p"/projects/#{@project.slug}/test-definitions/#{@test_definition.id}/edit"}
              >
                <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
              </.button>
            </:actions>
          </.page_header>
        </div>

        <div class="grid grid-cols-1 items-start gap-6 lg:grid-cols-[minmax(0,1fr)_minmax(0,24rem)]">
          <div class="space-y-6">
            <.panel id="run-now" title={gettext("Run now")}>
              <p
                :if={!@test_definition.enabled}
                id="run-now-disabled"
                class="flex items-center gap-2 border-b border-base-300 bg-warning/5 px-5 py-3 text-sm text-base-content/70"
              >
                <.icon name="hero-pause-circle-mini" class="size-4 shrink-0 text-warning" />
                {gettext("This test definition is disabled. Enable it to run it.")}
              </p>

              <.empty_state
                :if={@environments == []}
                id="run-now-no-environments"
                icon="hero-globe-alt"
                title={gettext("No environments yet")}
                compact
              >
                {gettext("A run needs an environment to point the suite at.")}
                <:actions>
                  <.button navigate={~p"/projects/#{@project.slug}/environments/new"}>
                    <.icon name="hero-plus-mini" class="size-4" /> {gettext("New environment")}
                  </.button>
                </:actions>
              </.empty_state>

              <ul :if={@environments != []} class="divide-y divide-base-300">
                <li
                  :for={environment <- @environments}
                  id={"run-now-environment-#{environment.id}"}
                  class="flex items-center justify-between gap-4 px-5 py-3"
                >
                  <div class="min-w-0">
                    <p class="truncate text-sm font-medium">{environment.name}</p>
                    <p class="truncate text-xs text-base-content/60">
                      <span class="font-mono">{environment.slug}</span>
                      · {ngettext(
                        "1 run at a time",
                        "up to %{count} runs at a time",
                        environment.max_concurrent_runs
                      )}
                    </p>
                  </div>
                  <.button
                    id={"run-now-#{environment.id}"}
                    variant="primary"
                    size="sm"
                    phx-click="run"
                    phx-value-environment={environment.id}
                    phx-disable-with={gettext("Starting...")}
                    disabled={!@test_definition.enabled}
                  >
                    <.icon name="hero-play-mini" class="size-4" /> {gettext("Run")}
                  </.button>
                </li>
              </ul>
            </.panel>

            <.panel id="test-definition-runs" title={gettext("Recent runs")}>
              <ul id="run-list" phx-update="stream" class="divide-y divide-base-300">
                <li id="runs-empty" class="hidden only:block">
                  <.empty_state
                    id="runs-empty-state"
                    icon="hero-play-circle"
                    title={gettext("No runs yet")}
                    compact
                  >
                    {gettext("Start one above.")}
                  </.empty_state>
                </li>
                <.run_row
                  :for={{id, run} <- @streams.runs}
                  id={id}
                  run={run}
                  context={:test_definition}
                />
              </ul>
            </.panel>
          </div>

          <.panel id="test-definition-settings" title={gettext("Settings")}>
            <dl class="divide-y divide-base-300 text-sm">
              <.setting label={gettext("Image")}>
                <span class="font-mono text-xs break-all">{@test_definition.image}</span>
              </.setting>
              <.setting label={gettext("Command")}>
                <code
                  :if={@test_definition.command != []}
                  class="font-mono text-xs break-all whitespace-pre-wrap"
                >{Enum.join(@test_definition.command, " ")}</code>
                <span :if={@test_definition.command == []} class="text-base-content/60">
                  {gettext("the image's entrypoint")}
                </span>
              </.setting>
              <.setting label={gettext("Timeout")}>
                {format_timeout(@test_definition.timeout_seconds)}
              </.setting>
              <.setting label={gettext("CPUs")}>
                {@test_definition.cpu_limit || gettext("unlimited")}
              </.setting>
              <.setting label={gettext("Memory")}>
                {if @test_definition.memory_limit,
                  do: format_bytes(@test_definition.memory_limit),
                  else: gettext("unlimited")}
              </.setting>
              <.setting label={gettext("Shared memory")}>
                {format_bytes(@test_definition.shm_size_bytes)}
              </.setting>
              <.setting label={gettext("Slug")}>
                <span class="font-mono text-xs">{@test_definition.slug}</span>
              </.setting>
            </dl>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp setting(assigns) do
    ~H"""
    <div class="grid grid-cols-[7rem_minmax(0,1fr)] gap-3 px-5 py-3">
      <dt class="text-base-content/60">{@label}</dt>
      <dd class="min-w-0">{render_slot(@inner_block)}</dd>
    </div>
    """
  end
end
