defmodule TestFleetWeb.ProjectLive.Form do
  use TestFleetWeb, :live_view

  alias TestFleet.Projects
  alias TestFleet.Projects.Project

  @impl true
  def mount(params, _session, socket) do
    {:ok, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{}

    socket
    |> assign(:page_title, gettext("New project"))
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
  end

  defp apply_action(socket, :edit, %{"slug" => slug}) do
    project = Projects.get_project_by_slug!(slug)

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: project.name))
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
  end

  @impl true
  def handle_event("validate", %{"project" => params}, socket) do
    changeset = Projects.change_project(socket.assigns.project, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"project" => params}, socket) do
    save(socket, socket.assigns.live_action, params)
  end

  defp save(socket, :new, params) do
    case Projects.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Project created."))
         |> push_navigate(to: ~p"/projects/#{project.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp save(socket, :edit, params) do
    case Projects.update_project(socket.assigns.project, params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Project saved."))
         |> push_navigate(to: ~p"/projects/#{project.slug}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp back_path(%Project{id: nil}), do: ~p"/projects"
  defp back_path(project), do: ~p"/projects/#{project.slug}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:projects}>
      <div class="space-y-8">
        <div>
          <.breadcrumbs>
            <:crumb navigate={~p"/projects"}>{gettext("Projects")}</:crumb>
            <:crumb :if={@project.id} navigate={back_path(@project)}>{@project.name}</:crumb>
            <:crumb>{if @project.id, do: gettext("Edit"), else: gettext("New")}</:crumb>
          </.breadcrumbs>
          <.page_header title={@page_title} />
        </div>

        <.form for={@form} id="project-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="Customer Portal" />
            <.slug_input
              field={@form[:slug]}
              source={@form[:name]}
              label={gettext("Slug")}
              hint={gettext("Used in URLs and in the API. Lowercase letters, digits, and dashes.")}
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label={gettext("Description")}
              rows="3"
            />

            <:footer>
              <.button navigate={back_path(@project)}>{gettext("Cancel")}</.button>
              <.button id="save-project" variant="primary" phx-disable-with={gettext("Saving...")}>
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
