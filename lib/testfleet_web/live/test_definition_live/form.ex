defmodule TestFleetWeb.TestDefinitionLive.Form do
  @moduledoc """
  Creates, edits, and deletes a test definition.

  Below the image, the form shows which registry's credentials a pull will use.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.{Projects, Registries, TestDefinitions}
  alias TestFleet.Execution.Docker.ImageRef
  alias TestFleet.TestDefinitions.TestDefinition

  @impl true
  def mount(%{"slug" => slug} = params, _session, socket) do
    project = Projects.get_project_by_slug!(socket.assigns.current_scope, slug)

    {:ok,
     socket
     |> assign(:project, project)
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    test_definition = %TestDefinition{project_id: socket.assigns.project.id}

    socket
    |> assign(:page_title, gettext("New test definition"))
    |> assign(:test_definition, test_definition)
    |> assign_form(TestDefinitions.change_test_definition(test_definition))
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    test_definition = TestDefinitions.get_test_definition!(socket.assigns.project, id)

    socket
    |> assign(:page_title, gettext("Edit %{name}", name: test_definition.name))
    |> assign(:test_definition, test_definition)
    |> assign_form(TestDefinitions.change_test_definition(test_definition))
  end

  # Without `action`, the form keeps the changeset's own action, e.g. :insert after a
  # failed save; passing `action: nil` would hide its errors.
  defp assign_form(socket, changeset, action \\ nil) do
    image = Ecto.Changeset.get_field(changeset, :image)
    form = if action, do: to_form(changeset, action: action), else: to_form(changeset)

    socket
    |> assign(:form, form)
    |> assign(:image_source, resolve_image_source(socket.assigns.current_scope, image))
  end

  # Where the image will be pulled from: a registry with credentials, anonymously, or
  # nothing to say yet.
  defp resolve_image_source(_scope, image) when image in [nil, ""], do: nil

  defp resolve_image_source(scope, image) do
    with {:ok, %ImageRef{host: host}} <- ImageRef.parse(image) do
      case Registries.get_registry_for_image(scope, image) do
        nil -> {:anonymous, host}
        registry -> {:registry, Registries.redact(registry)}
      end
    else
      _ -> nil
    end
  end

  @impl true
  def handle_event("validate", %{"test_definition" => params}, socket) do
    changeset = TestDefinitions.change_test_definition(socket.assigns.test_definition, params)
    {:noreply, assign_form(socket, changeset, :validate)}
  end

  def handle_event("save", %{"test_definition" => params}, socket) do
    %{project: project, test_definition: test_definition} = socket.assigns

    result =
      case socket.assigns.live_action do
        :new -> TestDefinitions.create_test_definition(project, params)
        :edit -> TestDefinitions.update_test_definition(test_definition, params)
      end

    case result do
      {:ok, test_definition} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Test definition %{name} saved.", name: test_definition.name)
         )
         # The assigned definition, not the saved one: a new one returns to the project.
         |> push_navigate(
           to: return_path(socket.assigns.organization, project, socket.assigns.test_definition)
         )}

      {:error, changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  def handle_event("delete", _params, socket) do
    %{project: project, test_definition: test_definition} = socket.assigns

    case TestDefinitions.delete_test_definition(test_definition) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           gettext("Test definition %{name} deleted.", name: test_definition.name)
         )
         |> push_navigate(to: ~p"/#{socket.assigns.organization}/projects/#{project.slug}")}

      {:error, :has_runs} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This test definition has runs and cannot be deleted. Disable it instead to stop new runs."
           )
         )}
    end
  end

  # A new definition returns to the project, an edited one to its own page.
  defp return_path(organization, project, %TestDefinition{id: nil}),
    do: ~p"/#{organization}/projects/#{project.slug}"

  defp return_path(organization, project, test_definition),
    do: ~p"/#{organization}/projects/#{project.slug}/test-definitions/#{test_definition.id}"

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

            <:crumb
              :if={@test_definition.id}
              navigate={
                ~p"/#{@organization}/projects/#{@project.slug}/test-definitions/#{@test_definition.id}"
              }
            >
              {@test_definition.name}
            </:crumb>

            <:crumb>
              {if @test_definition.id, do: gettext("Edit"), else: gettext("New test definition")}
            </:crumb>
          </.breadcrumbs>

          <.page_header title={@page_title}>
            <:actions :if={@test_definition.id}>
              <.button
                id="delete-test-definition"
                variant="danger"
                phx-click="delete"
                data-confirm={
                  gettext("Delete %{name} and its schedules?", name: @test_definition.name)
                }
              >
                <.icon name="hero-trash-mini" class="size-4" /> {gettext("Delete")}
              </.button>
            </:actions>
          </.page_header>
        </div>

        <.form for={@form} id="test-definition-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} placeholder="Customer Portal E2E" />
            <.slug_input
              field={@form[:slug]}
              source={@form[:name]}
              label={gettext("Slug")}
              hint={gettext("Names this suite in the API. Lowercase letters, digits, and dashes.")}
            />
            <.input
              field={@form[:description]}
              type="textarea"
              label={gettext("Description")}
              rows="2"
            />
            <.form_section title={gettext("Container")}>
              <div class="space-y-2">
                <.input
                  field={@form[:image]}
                  label={gettext("Image")}
                  placeholder="registry.company.com/customer-a/e2e:1.17"
                  autocomplete="off"
                  spellcheck="false"
                  mono
                  hint={
                    gettext(
                      "Prefer a fixed tag or a digest. Mutable tags work too; every run records the digest it used."
                    )
                  }
                /> <.image_source source={@image_source} organization={@organization} />
              </div>

              <.input
                field={@form[:command_text]}
                type="textarea"
                label={gettext("Command")}
                rows="3"
                placeholder="./run-e2e.sh"
                spellcheck="false"
                mono
                hint={
                  gettext(
                    "One argument per line, no shell. Leave empty to use the image's own entrypoint."
                  )
                }
              />
            </.form_section>

            <.form_section title={gettext("Limits")}>
              <div class="grid gap-5 sm:grid-cols-2">
                <.input
                  field={@form[:timeout_minutes]}
                  type="number"
                  min="1"
                  max="1440"
                  label={gettext("Timeout (minutes)")}
                  hint={gettext("The run is stopped after this time.")}
                />
                <.input
                  field={@form[:cpu_limit]}
                  type="number"
                  min="0.1"
                  step="0.1"
                  label={gettext("CPUs")}
                  placeholder={gettext("unlimited")}
                />
                <.input
                  field={@form[:memory_limit_mib]}
                  type="number"
                  min="6"
                  label={gettext("Memory (MiB)")}
                  placeholder={gettext("unlimited")}
                  hint={gettext("A suite over this limit ends as an error.")}
                />
                <.input
                  field={@form[:shm_size_mib]}
                  type="number"
                  min="1"
                  label={gettext("Shared memory (MiB)")}
                  hint={gettext("/dev/shm. Browsers crash with Docker's default of 64 MiB.")}
                />
              </div>
            </.form_section>

            <.input
              field={@form[:enabled]}
              type="checkbox"
              label={gettext("Enabled")}
              hint={gettext("Disabled test definitions cannot be run or scheduled.")}
            />
            <:footer>
              <.button navigate={return_path(@organization, @project, @test_definition)}>
                {gettext("Cancel")}
              </.button>

              <.button
                id="save-test-definition"
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

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp form_section(assigns) do
    ~H"""
    <fieldset class="space-y-5 border-t border-base-300 pt-5">
      <legend class="sr-only">{@title}</legend>

      <h3
        aria-hidden="true"
        class="text-xs font-semibold tracking-wide text-base-content/50 uppercase"
      >
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </fieldset>
    """
  end

  attr :source, :any, required: true
  attr :organization, :any, required: true

  defp image_source(%{source: nil} = assigns), do: ~H""

  defp image_source(%{source: {:registry, registry}} = assigns) do
    assigns = assign(assigns, :registry, registry)

    ~H"""
    <p id="image-source" class="flex items-center gap-1.5 text-xs text-success">
      <.icon name="hero-key-mini" class="size-3.5 shrink-0" />
      <span>
        {gettext("Pulled with the credentials of")}
        <.link
          navigate={~p"/#{@organization}/registries/#{@registry.id}/edit"}
          class="font-medium underline decoration-success/40 underline-offset-2 hover:decoration-success"
        >
          {@registry.name}
        </.link>
      </span>
    </p>
    """
  end

  defp image_source(%{source: {:anonymous, host}} = assigns) do
    assigns = assign(assigns, :host, host)

    ~H"""
    <p id="image-source" class="flex items-center gap-1.5 text-xs text-base-content/60">
      <.icon name="hero-globe-alt-mini" class="size-3.5 shrink-0" />
      <span>
        {gettext("No registry for %{host}: pulled anonymously.", host: @host)}
        <.link
          navigate={~p"/#{@organization}/registries/new"}
          class="font-medium underline decoration-base-content/30 underline-offset-2 hover:text-base-content"
        >
          {gettext("Add credentials")}
        </.link>
      </span>
    </p>
    """
  end
end
