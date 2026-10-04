defmodule TestFleetWeb.OrganizationLive.Settings do
  @moduledoc """
  The organization's name and slug (admins). The slug is the first segment of every
  page's URL: changing it breaks links that contain the old one.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Organizations

  @impl true
  def mount(_params, _session, socket) do
    organization = socket.assigns.organization

    {:ok,
     socket
     |> assign(:page_title, gettext("Organization settings"))
     |> assign(:form, to_form(Organizations.change_organization(organization)))}
  end

  @impl true
  def handle_event("validate", %{"organization" => params}, socket) do
    changeset = Organizations.change_organization(socket.assigns.organization, params)
    {:noreply, assign(socket, :form, to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"organization" => params}, socket) do
    case Organizations.update_organization(socket.assigns.organization, params) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Organization saved."))
         |> push_navigate(to: ~p"/#{organization}/settings")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:settings}>
      <div class="space-y-8">
        <.page_header
          title={gettext("Organization settings")}
          description={gettext("The organization's name, and the slug in its URLs.")}
        />

        <.form for={@form} id="organization-form" phx-change="validate" phx-submit="save">
          <.form_card>
            <.input field={@form[:name]} label={gettext("Name")} />
            <.slug_input
              field={@form[:slug]}
              source={@form[:name]}
              label={gettext("Slug")}
              hint={
                gettext(
                  "The first part of every page's URL. Links that contain the old slug stop working; links to runs keep working."
                )
              }
            />

            <:footer>
              <.button navigate={~p"/#{@organization}"}>{gettext("Cancel")}</.button>
              <.button
                id="save-organization"
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
