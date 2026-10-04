defmodule TestFleetWeb.OrganizationLive.Index do
  @moduledoc """
  The user's organizations, to choose one. `/` opens it directly when there is
  only one.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Organizations

  @impl true
  def mount(_params, _session, socket) do
    memberships = Organizations.list_memberships(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:page_title, gettext("Organizations"))
     |> assign(:memberships_empty?, memberships == [])
     |> stream(:memberships, memberships)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <.page_header
          title={gettext("Organizations")}
          description={gettext("Choose the organization to work in.")}
        />

        <.empty_state
          :if={@memberships_empty?}
          id="organizations-empty"
          icon="hero-building-office-2"
          title={gettext("You do not belong to an organization yet")}
        >
          {gettext("Ask an admin of your organization to invite you.")}
        </.empty_state>

        <ul
          :if={!@memberships_empty?}
          id="organizations"
          phx-update="stream"
          class="divide-y divide-base-300 overflow-hidden rounded-2xl border border-base-300 bg-base-100"
        >
          <li :for={{id, membership} <- @streams.memberships} id={id}>
            <.link
              navigate={~p"/#{membership.organization}"}
              id={"organization-#{membership.organization.slug}"}
              class="flex items-center justify-between gap-4 px-5 py-4 transition-colors hover:bg-base-200/60"
            >
              <span class="font-medium">{membership.organization.name}</span>
              <.badge tone={if(membership.role == :admin, do: :primary, else: :neutral)}>
                {Layouts.role_label(membership.role)}
              </.badge>
            </.link>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
