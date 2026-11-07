defmodule TestFleetWeb.TestDefinitionLive.Show do
  @moduledoc """
  A test definition: its settings, "Run now" per environment, its recent runs,
  and its flaky tests per environment.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Results, Retention, Runs, TestDefinitions}
  alias TestFleetWeb.RunFeed

  @recent_runs 20

  @impl true
  def mount(%{"slug" => slug, "id" => id}, _session, socket) do
    project = Projects.get_project_by_slug!(socket.assigns.current_scope, slug)
    test_definition = TestDefinitions.get_test_definition!(project, id)
    environments = Environments.list_environments(project)

    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, test_definition.name)
     |> assign(:project, project)
     |> assign(:test_definition, test_definition)
     |> assign(:environments, environments)
     |> assign(:window_size, Results.window_size())
     |> assign(:flaky_environment, List.first(environments))
     |> load_flaky()
     |> RunFeed.init(
       :runs,
       Runs.list_runs(socket.assigns.current_scope,
         test_definition: test_definition,
         limit: @recent_runs
       )
     )}
  end

  defp load_flaky(%{assigns: %{flaky_environment: nil}} = socket), do: socket

  defp load_flaky(socket) do
    %{test_definition: test_definition, flaky_environment: environment} = socket.assigns

    assign_async(socket, :flaky, fn ->
      {:ok, %{flaky: Results.flaky_tests(test_definition, environment)}}
    end)
  end

  @impl true
  def handle_event("run", %{"environment" => environment_id}, socket) do
    environment = Enum.find(socket.assigns.environments, &(to_string(&1.id) == environment_id))

    user = socket.assigns.current_scope.user

    case environment && Runs.create_run(socket.assigns.test_definition, environment, user: user) do
      {:ok, run} ->
        {:noreply, push_navigate(socket, to: ~p"/#{socket.assigns.organization}/runs/#{run.id}")}

      {:error, :test_definition_disabled} ->
        {:noreply,
         put_flash(socket, :error, gettext("This test definition is disabled and cannot run."))}

      _ ->
        {:noreply, put_flash(socket, :error, gettext("This environment no longer exists."))}
    end
  end

  def handle_event("flaky_environment", %{"id" => environment_id}, socket) do
    case Enum.find(socket.assigns.environments, &(to_string(&1.id) == environment_id)) do
      nil ->
        {:noreply, socket}

      environment ->
        {:noreply, socket |> assign(:flaky_environment, environment) |> load_flaky()}
    end
  end

  @impl true
  def handle_info({event, run} = message, socket)
      when event in [:run_created, :run_updated, :run_finished, :run_deleted] do
    if run.test_definition_id == socket.assigns.test_definition.id do
      {:noreply,
       socket
       |> RunFeed.apply_event(:runs, message, @recent_runs)
       |> maybe_reload_flaky(message)}
    else
      {:noreply, socket}
    end
  end

  # A finished run with JUnit in the chosen environment moves its window.
  defp maybe_reload_flaky(socket, {:run_finished, %{environment_id: id, tests_passed: passed}})
       when passed != nil do
    case socket.assigns.flaky_environment do
      %{id: ^id} -> load_flaky(socket)
      _other -> socket
    end
  end

  defp maybe_reload_flaky(socket, _message), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div id="test-definition" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/#{@organization}/projects"}>{gettext("Projects")}</:crumb>

            <:crumb navigate={~p"/#{@organization}/projects/#{@project.slug}"}>
              {@project.name}
            </:crumb>

            <:crumb>{@test_definition.name}</:crumb>
          </.breadcrumbs>

          <.page_header title={@test_definition.name} description={@test_definition.description}>
            <:actions>
              <.badge :if={!@test_definition.enabled} tone={:warning}>{gettext("disabled")}</.badge>

              <.button
                id="edit-test-definition"
                navigate={
                  ~p"/#{@organization}/projects/#{@project.slug}/test-definitions/#{@test_definition.id}/edit"
                }
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
                <.icon name="hero-pause-circle-mini" class="size-4 shrink-0 text-warning" /> {gettext(
                  "This test definition is disabled. Enable it to run it."
                )}
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
                  <.button navigate={~p"/#{@organization}/projects/#{@project.slug}/environments/new"}>
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

            <.panel :if={@flaky_environment} id="flaky-tests" title={gettext("Flaky tests")}>
              <:actions :if={length(@environments) > 1}>
                <nav
                  id="flaky-environments"
                  aria-label={gettext("Environment")}
                  class="flex flex-wrap items-center rounded-lg bg-base-200 p-0.5 text-xs font-medium"
                >
                  <button
                    :for={environment <- @environments}
                    id={"flaky-environment-#{environment.id}"}
                    type="button"
                    phx-click="flaky_environment"
                    phx-value-id={environment.id}
                    aria-pressed={to_string(environment.id == @flaky_environment.id)}
                    class={[
                      "cursor-pointer rounded-md px-2.5 py-1 transition-colors",
                      if(environment.id == @flaky_environment.id,
                        do: "bg-base-100 text-base-content shadow-sm",
                        else: "text-base-content/60 hover:text-base-content"
                      )
                    ]}
                  >
                    {environment.name}
                  </button>
                </nav>
              </:actions>

              <.async_result :let={tests} assign={@flaky}>
                <:loading>
                  <p
                    id="flaky-tests-loading"
                    class="flex items-center gap-2 px-5 py-4 text-sm text-base-content/60"
                  >
                    <.icon name="hero-arrow-path-mini" class="size-4 animate-spin" />
                    {gettext("Looking for flaky tests…")}
                  </p>
                </:loading>
                <:failed :let={_reason}>
                  <p id="flaky-tests-failed" class="px-5 py-4 text-sm text-base-content/60">
                    {gettext("The flaky tests could not be loaded.")}
                  </p>
                </:failed>

                <p
                  :if={tests == []}
                  id="flaky-tests-none"
                  class="flex items-center gap-2 px-5 py-4 text-sm text-base-content/70"
                >
                  <.icon name="hero-check-circle" class="size-5 text-success" />
                  {gettext("No flaky tests in the last %{count} runs.", count: @window_size)}
                </p>

                <ul :if={tests != []} id="flaky-test-list" class="divide-y divide-base-300">
                  <li
                    :for={{flaky, index} <- Enum.with_index(tests)}
                    id={"flaky-test-#{index}"}
                    class="flex items-center gap-4 px-5 py-3 transition-colors hover:bg-base-200/40"
                  >
                    <.icon name="hero-arrows-right-left-mini" class="size-4 shrink-0 text-warning" />
                    <div class="min-w-0 flex-1">
                      <.link
                        navigate={
                          test_path(@organization, @project.slug, @test_definition.id, flaky.test)
                        }
                        data-test-link
                        class="block truncate text-sm font-medium transition-colors hover:text-primary"
                      >
                        {flaky.test.name}
                      </.link>
                      <p
                        :if={test_location(flaky.test) != ""}
                        class="truncate text-xs text-base-content/60"
                      >
                        {test_location(flaky.test)}
                      </p>
                    </div>
                    <div class="shrink-0 text-right text-xs">
                      <p data-flips class="font-medium text-warning tabular-nums">
                        {ngettext("1 flip", "%{count} flips", flaky.flips)}
                        <span class="font-normal text-base-content/60">
                          {ngettext("in 1 run", "in %{count} runs", flaky.runs)}
                        </span>
                      </p>
                      <.link
                        :if={flaky.last_flip_run_id}
                        navigate={~p"/#{@organization}/runs/#{flaky.last_flip_run_id}"}
                        class="text-base-content/60 tabular-nums transition-colors hover:text-primary"
                      >
                        {gettext("latest #%{id}", id: flaky.last_flip_run_id)}
                      </.link>
                    </div>
                  </li>
                </ul>
              </.async_result>
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

              <.setting label={gettext("Artifacts")}>
                <.retention
                  days={@test_definition.artifact_retention_days}
                  default={Retention.artifacts_days()}
                />
              </.setting>

              <.setting label={gettext("Logs")}>
                <.retention
                  days={@test_definition.log_retention_days}
                  default={Retention.logs_days()}
                />
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

  attr :days, :integer, required: true
  attr :default, :integer, required: true

  # How long a suite keeps its artifacts or logs; empty is the instance default.
  defp retention(assigns) do
    ~H"""
    {ngettext("%{count} day", "%{count} days", @days || @default)}
    <span :if={is_nil(@days)} class="text-base-content/60">{gettext("(default)")}</span>
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
