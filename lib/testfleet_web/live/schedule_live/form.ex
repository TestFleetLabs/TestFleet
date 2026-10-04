defmodule TestFleetWeb.ScheduleLive.Form do
  @moduledoc """
  Creates, edits, and deletes a schedule, with a preview of the next run times.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects, Schedules, TestDefinitions}
  alias TestFleet.Schedules.{Schedule, Timezones}

  @presets [
    {"Every day at 06:00", "0 6 * * *"},
    {"Weekdays at 06:00", "0 6 * * 1-5"},
    {"Every hour", "0 * * * *"},
    {"Every 15 minutes", "*/15 * * * *"}
  ]

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    project = Projects.get_project_by_slug!(socket.assigns.current_scope, slug)

    {:ok,
     socket
     |> assign(:project, project)
     |> assign(:test_definitions, TestDefinitions.list_test_definitions(project))
     |> assign(:environments, Environments.list_environments(project))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    %{test_definitions: test_definitions, environments: environments} = socket.assigns

    # With only one choice, there is nothing to choose.
    schedule = %Schedule{
      timezone: Timezones.default(),
      test_definition_id: single_id(Enum.filter(test_definitions, & &1.enabled)),
      environment_id: single_id(environments)
    }

    socket
    |> assign(:page_title, gettext("New schedule"))
    |> assign(:schedule, schedule)
    |> assign_form(Schedules.change_schedule(socket.assigns.project, schedule))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    schedule = Schedules.get_schedule!(socket.assigns.project, id)

    socket
    |> assign(:page_title, gettext("Edit schedule"))
    |> assign(:schedule, schedule)
    |> assign_form(Schedules.change_schedule(socket.assigns.project, schedule))
  end

  defp single_id([%{id: id}]), do: id
  defp single_id(_), do: nil

  # Without `action`, the form keeps the changeset's own action, e.g. :insert after a
  # failed save; passing `action: nil` would hide its errors.
  defp assign_form(socket, changeset, action \\ nil) do
    form = if action, do: to_form(changeset, action: action), else: to_form(changeset)
    expression = Ecto.Changeset.get_field(changeset, :cron_expression)
    timezone = Ecto.Changeset.get_field(changeset, :timezone)

    socket
    |> assign(:form, form)
    |> assign(:preview_timezone, timezone)
    |> assign(:preview, Schedules.preview(expression, timezone, 3))
  end

  @impl true
  def handle_event("validate", %{"schedule" => params}, socket) do
    changeset = Schedules.change_schedule(socket.assigns.project, socket.assigns.schedule, params)
    {:noreply, assign_form(socket, changeset, :validate)}
  end

  def handle_event("preset", %{"cron" => cron}, socket) do
    params = Map.put(socket.assigns.form.params, "cron_expression", cron)
    changeset = Schedules.change_schedule(socket.assigns.project, socket.assigns.schedule, params)
    {:noreply, assign_form(socket, changeset, :validate)}
  end

  def handle_event("save", %{"schedule" => params}, socket) do
    %{project: project, schedule: schedule} = socket.assigns

    result =
      case socket.assigns.live_action do
        :new -> Schedules.create_schedule(project, params)
        :edit -> Schedules.update_schedule(project, schedule, params)
      end

    case result do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Schedule saved."))
         |> push_navigate(to: ~p"/#{socket.assigns.organization}/projects/#{project.slug}")}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Schedules.delete_schedule(socket.assigns.schedule)

    {:noreply,
     socket
     |> put_flash(:info, gettext("Schedule deleted."))
     |> push_navigate(
       to: ~p"/#{socket.assigns.organization}/projects/#{socket.assigns.project.slug}"
     )}
  end

  defp test_definition_options(test_definitions, current_id) do
    for test_definition <- test_definitions,
        test_definition.enabled or test_definition.id == current_id do
      label =
        if test_definition.enabled,
          do: test_definition.name,
          else: gettext("%{name} (disabled)", name: test_definition.name)

      {label, test_definition.id}
    end
  end

  defp timezone_options(current) do
    zones = Timezones.list()
    if current in [nil, ""] or current in zones, do: zones, else: [current | zones]
  end

  defp overlap_options do
    [
      {gettext("Skip: don't start while the previous run is still active"), :skip},
      {gettext("Queue: start once the previous run has finished"), :queue},
      {gettext("Allow: run in parallel"), :allow}
    ]
  end

  defp can_schedule?(test_definitions, environments) do
    Enum.any?(test_definitions, & &1.enabled) and environments != []
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :presets, @presets)

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/#{@organization}/projects"}>{gettext("Projects")}</:crumb>

            <:crumb navigate={~p"/#{@organization}/projects/#{@project.slug}"}>
              {@project.name}
            </:crumb>

            <:crumb>{@page_title}</:crumb>
          </.breadcrumbs>

          <.page_header title={@page_title}>
            <:actions :if={@schedule.id}>
              <.button
                id="delete-schedule"
                variant="danger"
                phx-click="delete"
                data-confirm={gettext("Delete this schedule?")}
              >
                <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
              </.button>
            </:actions>
          </.page_header>
        </div>

        <.empty_state
          :if={!@schedule.id and !can_schedule?(@test_definitions, @environments)}
          id="schedule-prerequisites"
          icon="hero-calendar"
          title={gettext("Nothing to schedule yet")}
        >
          {gettext("A schedule needs an enabled test definition and an environment of this project.")}
          <:actions>
            <.button
              :if={!Enum.any?(@test_definitions, & &1.enabled)}
              navigate={~p"/#{@organization}/projects/#{@project.slug}/test-definitions/new"}
            >
              <.icon name="hero-beaker-mini" class="size-4" /> {gettext("New test definition")}
            </.button>

            <.button
              :if={@environments == []}
              navigate={~p"/#{@organization}/projects/#{@project.slug}/environments/new"}
            >
              <.icon name="hero-globe-alt-mini" class="size-4" /> {gettext("New environment")}
            </.button>
          </:actions>
        </.empty_state>

        <div
          :if={@schedule.id || can_schedule?(@test_definitions, @environments)}
          class="grid items-start gap-6 lg:grid-cols-[minmax(0,42rem)_minmax(0,1fr)]"
        >
          <.form for={@form} id="schedule-form" phx-change="validate" phx-submit="save">
            <.form_card>
              <div class="grid gap-5 sm:grid-cols-2">
                <.input
                  field={@form[:test_definition_id]}
                  type="select"
                  label={gettext("Test definition")}
                  prompt={gettext("Choose...")}
                  options={test_definition_options(@test_definitions, @schedule.test_definition_id)}
                />
                <.input
                  field={@form[:environment_id]}
                  type="select"
                  label={gettext("Environment")}
                  prompt={gettext("Choose...")}
                  options={Enum.map(@environments, &{&1.name, &1.id})}
                />
              </div>

              <div class="space-y-2">
                <.input
                  field={@form[:cron_expression]}
                  label={gettext("Cron expression")}
                  placeholder="0 6 * * *"
                  autocomplete="off"
                  spellcheck="false"
                  mono
                  hint={gettext("minute hour day-of-month month day-of-week, e.g. 0 6 * * 1-5")}
                />
                <div id="cron-presets" class="flex flex-wrap gap-1.5">
                  <button
                    :for={{label, cron} <- @presets}
                    type="button"
                    phx-click="preset"
                    phx-value-cron={cron}
                    class="cursor-pointer rounded-full border border-base-300 px-2.5 py-1 text-xs text-base-content/70 transition-colors duration-150 hover:border-primary/40 hover:bg-primary/5 hover:text-primary"
                  >
                    {label}
                  </button>
                </div>
              </div>

              <.input
                field={@form[:timezone]}
                type="select"
                label={gettext("Time zone")}
                options={timezone_options(@form[:timezone].value)}
                hint={
                  gettext(
                    "The cron expression is read in this time zone, including daylight saving time."
                  )
                }
              />
              <.input
                field={@form[:overlap_policy]}
                type="select"
                label={gettext("When the previous run is still active")}
                options={overlap_options()}
              />
              <.input
                field={@form[:enabled]}
                type="checkbox"
                label={gettext("Enabled")}
                hint={gettext("A disabled schedule keeps its settings but starts no runs.")}
              />
              <:footer>
                <.button navigate={~p"/#{@organization}/projects/#{@project.slug}"}>{gettext("Cancel")}</.button>
                <.button id="save-schedule" variant="primary" phx-disable-with={gettext("Saving...")}>
                  {gettext("Save")}
                </.button>
              </:footer>
            </.form_card>
          </.form>

          <.panel id="schedule-preview" title={gettext("Next runs")}>
            <ol :if={@preview != []} id="schedule-preview-runs" class="divide-y divide-base-300">
              <li
                :for={{run, index} <- Enum.with_index(@preview)}
                id={"schedule-preview-#{index}"}
                class="flex items-center gap-3 px-5 py-3 text-sm"
              >
                <span class="grid size-6 shrink-0 place-items-center rounded-full bg-primary/10 text-xs font-medium text-primary tabular-nums">
                  {index + 1}
                </span>
                <.local_time at={run} timezone={@preview_timezone} />
              </li>
            </ol>

            <p
              :if={@preview == []}
              id="schedule-preview-empty"
              class="px-5 py-6 text-sm text-base-content/60"
            >
              {gettext("Enter a valid cron expression and time zone to see when this schedule runs.")}
            </p>
          </.panel>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
