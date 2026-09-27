defmodule TestFleetWeb.EnvironmentLive.Show do
  @moduledoc """
  An environment and its variables.

  Secret values never reach the browser: variables are redacted before they are
  streamed or put into a form, and the environment is kept without its variables.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects}
  alias TestFleet.Environments.Variable

  @impl true
  def mount(%{"slug" => slug, "env" => env}, _session, socket) do
    project = Projects.get_project_by_slug!(slug)
    environment = Environments.get_environment!(project, env)
    variables = Enum.map(environment.variables, &Environments.redact/1)

    {:ok,
     socket
     |> assign(:page_title, environment.name)
     |> assign(:project, project)
     |> assign(:environment, %{environment | variables: []})
     |> assign(:variable_count, length(variables))
     |> assign(:editing, nil)
     |> assign_variable_form(%Variable{})
     |> stream(:variables, variables)}
  end

  defp assign_variable_form(socket, variable, params \\ %{}, action \\ nil) do
    changeset = Environments.change_variable(variable, params)
    assign(socket, :variable_form, to_form(changeset, action: action))
  end

  # The changeset of a failed update holds the stored value; it must not reach the form.
  defp redacted_form(changeset) do
    to_form(%{changeset | data: Environments.redact(changeset.data)})
  end

  @impl true
  def handle_event("validate_variable", %{"variable" => params}, socket) do
    variable = socket.assigns.editing || %Variable{}
    {:noreply, assign_variable_form(socket, variable, params, :validate)}
  end

  def handle_event("save_variable", %{"variable" => params}, socket) do
    %{environment: environment, editing: editing} = socket.assigns

    result =
      if editing do
        environment
        |> Environments.get_variable!(editing.id)
        |> Environments.update_variable(params)
      else
        Environments.create_variable(environment, params)
      end

    case result do
      {:ok, variable} ->
        {:noreply,
         socket
         |> update(:variable_count, &if(editing, do: &1, else: &1 + 1))
         |> assign(:editing, nil)
         |> assign_variable_form(%Variable{})
         |> stream_insert(:variables, Environments.redact(variable))}

      {:error, changeset} ->
        {:noreply, assign(socket, :variable_form, redacted_form(changeset))}
    end
  end

  def handle_event("edit_variable", %{"id" => id}, socket) do
    variable =
      socket.assigns.environment |> Environments.get_variable!(id) |> Environments.redact()

    {:noreply,
     socket
     |> restream_editing()
     |> assign(:editing, variable)
     |> assign_variable_form(variable)
     |> stream_insert(:variables, variable)}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> restream_editing()
     |> assign(:editing, nil)
     |> assign_variable_form(%Variable{})}
  end

  def handle_event("delete_variable", %{"id" => id}, socket) do
    variable = Environments.get_variable!(socket.assigns.environment, id)
    {:ok, _} = Environments.delete_variable(variable)

    socket =
      if socket.assigns.editing && socket.assigns.editing.id == variable.id do
        socket |> assign(:editing, nil) |> assign_variable_form(%Variable{})
      else
        socket
      end

    {:noreply,
     socket
     |> update(:variable_count, &(&1 - 1))
     |> stream_delete(:variables, variable)}
  end

  def handle_event("delete", _params, socket) do
    %{project: project, environment: environment} = socket.assigns

    case Environments.delete_environment(environment) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Environment %{name} deleted.", name: environment.name))
         |> push_navigate(to: ~p"/projects/#{project.slug}")}

      {:error, :has_runs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This environment has runs and cannot be deleted; its run history would be lost."
           )
         )}
    end
  end

  # Re-renders the row that was highlighted as being edited.
  defp restream_editing(%{assigns: %{editing: nil}} = socket), do: socket

  defp restream_editing(%{assigns: %{editing: editing}} = socket) do
    socket = assign(socket, :editing, nil)
    stream_insert(socket, :variables, editing)
  end

  defp secret_checked?(form) do
    Phoenix.HTML.Form.normalize_value("checkbox", form[:secret].value)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:projects}>
      <div id="environment" class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/projects"}>{gettext("Projects")}</:crumb>
            <:crumb navigate={~p"/projects/#{@project.slug}"}>{@project.name}</:crumb>
            <:crumb>{@environment.name}</:crumb>
          </.breadcrumbs>

          <.page_header title={@environment.name} description={@environment.description}>
            <:actions>
              <.button
                id="edit-environment"
                navigate={~p"/projects/#{@project.slug}/environments/#{@environment.slug}/edit"}
              >
                <.icon name="hero-pencil-square-mini" class="size-4" /> {gettext("Edit")}
              </.button>
              <.button
                id="delete-environment"
                variant="danger"
                phx-click="delete"
                data-confirm={
                  gettext("Delete %{name} with its variables and schedules?",
                    name: @environment.name
                  )
                }
              >
                <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
              </.button>
            </:actions>
          </.page_header>

          <div class="mt-4 flex flex-wrap items-center gap-2">
            <.badge class="font-mono">{@environment.slug}</.badge>
            <.badge>
              <.icon name="hero-bolt-mini" class="size-3.5" />
              {ngettext(
                "at most 1 run at a time",
                "at most %{count} runs at a time",
                @environment.max_concurrent_runs
              )}
            </.badge>
          </div>
        </div>

        <.panel id="variables" title={gettext("Variables")}>
          <.form
            for={@variable_form}
            id="variable-form"
            phx-change="validate_variable"
            phx-submit="save_variable"
            class={[
              "border-b border-base-300 p-5 transition-colors duration-200",
              if(@editing, do: "bg-primary/5", else: "bg-base-200/30")
            ]}
          >
            <p :if={@editing} id="variable-form-editing" class="mb-4 text-sm font-medium">
              {gettext("Editing")}
              <code class="rounded bg-base-100 px-1.5 py-0.5 font-mono text-xs">{@editing.key}</code>
            </p>

            <div class="grid gap-4 sm:grid-cols-[minmax(0,16rem)_minmax(0,1fr)]">
              <.input
                field={@variable_form[:key]}
                label={gettext("Key")}
                placeholder="BASE_URL"
                autocomplete="off"
                spellcheck="false"
              />
              <.input
                field={@variable_form[:value]}
                type={if secret_checked?(@variable_form), do: "password", else: "text"}
                label={gettext("Value")}
                placeholder={if !@editing, do: "https://staging.example.com"}
                autocomplete="off"
                spellcheck="false"
                hint={
                  if @editing && @editing.secret,
                    do: gettext("Leave empty to keep the current value.")
                }
              />
            </div>

            <div class="mt-4 flex flex-wrap items-start justify-between gap-3">
              <.input
                field={@variable_form[:secret]}
                type="checkbox"
                label={gettext("Secret")}
                hint={
                  gettext(
                    "Never shown again after saving, and masked in run logs. At least %{count} characters.",
                    count: Variable.min_secret_length()
                  )
                }
              />
              <div class="flex gap-2">
                <.button
                  :if={@editing}
                  id="cancel-edit-variable"
                  type="button"
                  phx-click="cancel_edit"
                >
                  {gettext("Cancel")}
                </.button>
                <.button id="save-variable" variant="primary" phx-disable-with={gettext("Saving...")}>
                  {if @editing, do: gettext("Save variable"), else: gettext("Add variable")}
                </.button>
              </div>
            </div>
          </.form>

          <.empty_state
            :if={@variable_count == 0}
            id="variables-empty"
            icon="hero-variable"
            title={gettext("No variables yet")}
            compact
          >
            {gettext(
              "Variables are passed to the test container as environment variables, e.g. the URL of the system under test."
            )}
          </.empty_state>

          <div :if={@variable_count > 0} class="overflow-x-auto">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-base-300 text-xs font-medium tracking-wide text-base-content/60 uppercase">
                <tr>
                  <th class="px-5 py-3 font-medium">{gettext("Key")}</th>
                  <th class="px-5 py-3 font-medium">{gettext("Value")}</th>
                  <th class="px-5 py-3"><span class="sr-only">{gettext("Actions")}</span></th>
                </tr>
              </thead>
              <tbody id="variable-list" phx-update="stream" class="divide-y divide-base-300">
                <tr
                  :for={{id, variable} <- @streams.variables}
                  id={id}
                  class={[
                    "transition-colors duration-150",
                    if(@editing && @editing.id == variable.id,
                      do: "bg-primary/5",
                      else: "hover:bg-base-200/40"
                    )
                  ]}
                >
                  <td class="px-5 py-3 font-mono text-xs font-medium whitespace-nowrap">
                    {variable.key}
                  </td>
                  <td class="px-5 py-3 font-mono text-xs">
                    <%= cond do %>
                      <% variable.secret -> %>
                        <span class="inline-flex items-center gap-1.5 text-base-content/50">
                          <.icon name="hero-lock-closed-mini" class="size-3.5" /> ••••••••
                        </span>
                      <% variable.value == "" -> %>
                        <span class="text-base-content/40 italic">{gettext("empty")}</span>
                      <% true -> %>
                        <span class="block max-w-md truncate" title={variable.value}>
                          {variable.value}
                        </span>
                    <% end %>
                  </td>
                  <td class="w-0 px-5 py-2">
                    <div class="flex items-center justify-end gap-1">
                      <.button
                        id={"edit-variable-#{variable.id}"}
                        variant="ghost"
                        size="sm"
                        phx-click="edit_variable"
                        phx-value-id={variable.id}
                        aria-label={gettext("Edit %{key}", key: variable.key)}
                      >
                        <.icon name="hero-pencil-square-mini" class="size-4" />
                      </.button>
                      <.button
                        id={"delete-variable-#{variable.id}"}
                        variant="ghost"
                        size="sm"
                        phx-click="delete_variable"
                        phx-value-id={variable.id}
                        data-confirm={gettext("Delete %{key}?", key: variable.key)}
                        aria-label={gettext("Delete %{key}", key: variable.key)}
                      >
                        <.icon name="hero-trash-mini" class="size-4" />
                      </.button>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </.panel>
      </div>
    </Layouts.app>
    """
  end
end
