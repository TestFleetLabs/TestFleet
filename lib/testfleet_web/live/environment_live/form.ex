defmodule TestFleetWeb.EnvironmentLive.Form do
  use TestFleetWeb, :live_view

  alias TestFleet.{Environments, Projects}
  alias TestFleet.Environments.Environment

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    project = Projects.get_project_by_slug!(socket.assigns.current_scope, slug)

    {:ok,
     socket
     |> assign(:project, project)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    environment = %Environment{project_id: socket.assigns.project.id}

    socket
    |> assign(:page_title, gettext("New environment"))
    |> assign(:environment, environment)
    |> assign(:form, to_form(Environments.change_environment(environment)))
  end

  defp apply_action(socket, :edit, %{"env" => env}) do
    environment = Environments.get_environment!(socket.assigns.project, env)

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: environment.name))
    |> assign(:environment, environment)
    |> assign(:form, to_form(Environments.change_environment(environment)))
  end

  @impl true
  def handle_event("validate", %{"environment" => params}, socket) do
    changeset = Environments.change_environment(socket.assigns.environment, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"environment" => params}, socket) do
    %{project: project, environment: environment} = socket.assigns

    result =
      case socket.assigns.live_action do
        :new -> Environments.create_environment(project, params)
        :edit -> Environments.update_environment(environment, params)
      end

    case result do
      {:ok, environment} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Environment saved."))
         |> push_navigate(
           to:
             ~p"/#{socket.assigns.organization}/projects/#{project.slug}/environments/#{environment.slug}"
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp back_path(organization, project, %Environment{id: nil}),
    do: ~p"/#{organization}/projects/#{project.slug}"

  defp back_path(organization, project, environment),
    do: ~p"/#{organization}/projects/#{project.slug}/environments/#{environment.slug}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/#{@organization}/projects"}>{gettext("Projects")}</:crumb>

            <:crumb navigate={~p"/#{@organization}/projects/#{@project.slug}"}>
              {@project.name}
            </:crumb>

            <:crumb :if={@environment.id} navigate={back_path(@organization, @project, @environment)}>
              {@environment.name}
            </:crumb>

            <:crumb>
              {if @environment.id, do: gettext("Edit"), else: gettext("New environment")}
            </:crumb>
          </.breadcrumbs>
          <.page_header title={@page_title} />
        </div>

        <.form for={@form} id="environment-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="Production" />
            <.slug_input
              field={@form[:slug]}
              source={@form[:name]}
              label={gettext("Slug")}
              hint={gettext("Passed to the suite as TestFleet_ENVIRONMENT.")}
            />
            <.input
              field={@form[:max_concurrent_runs]}
              type="number"
              min="1"
              max="100"
              label={gettext("Maximum concurrent runs")}
              hint={
                gettext(
                  "How many runs may execute against this environment at the same time. Protects the target system."
                )
              }
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label={gettext("Description")}
              rows="3"
            />
            <:footer>
              <.button navigate={back_path(@organization, @project, @environment)}>{gettext("Cancel")}</.button>
              <.button
                id="save-environment"
                variant="primary"
                phx-disable-with={gettext("Saving...")}
              >
                {gettext("Save")}
              </.button>
            </:footer>
          </.form_card>
        </.form>
      </div>
    </Layouts.app>
    """
  end
end
