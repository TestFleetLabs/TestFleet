defmodule TestFleetWeb.UserLive.Index do
  @moduledoc """
  The Users page (admin, Milestone 10, section 9): invitations, roles, and
  deactivation. An invitation link is shown once, to copy; with SMTP it is also
  emailed.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{OIDC, User}
  alias TestFleet.Schedules.Timezones
  alias TestFleetWeb.UserAuth

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Users"))
     |> assign(:invite_form, to_form(Accounts.change_invitation(%{role: :member})))
     |> assign(:invite_link, nil)
     |> assign(:timezone, Timezones.default())
     |> assign(:provider_name, OIDC.provider_name())
     |> stream(:users, Accounts.list_users())}
  end

  @impl true
  def handle_event("validate_invite", %{"user" => params}, socket) do
    form = params |> Accounts.change_invitation() |> to_form(action: :validate)
    {:noreply, assign(socket, :invite_form, form)}
  end

  def handle_event("invite", %{"user" => params}, socket) do
    case Accounts.invite_user(params, &url(~p"/users/invitations/#{&1}")) do
      {:ok, invitation} ->
        {:noreply,
         socket
         |> assign(:invite_link, invitation)
         |> assign(:invite_form, to_form(Accounts.change_invitation(%{role: :member})))
         |> put_user(invitation.user)}

      {:error, changeset} ->
        {:noreply, assign(socket, :invite_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("dismiss_link", _params, socket) do
    {:noreply, assign(socket, :invite_link, nil)}
  end

  def handle_event("renew", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.renew_invitation(user, &url(~p"/users/invitations/#{&1}")) do
      {:ok, invitation} -> {:noreply, assign(socket, :invite_link, invitation)}
      {:error, :not_invited} -> {:noreply, refresh(socket, user)}
    end
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.revoke_invitation(user) do
      {:ok, user} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Invitation for %{email} revoked.", email: user.email))
         |> clear_link_for(user)
         |> stream_delete(:users, user)}

      {:error, :not_invited} ->
        {:noreply, refresh(socket, user)}
    end
  end

  def handle_event("set_role", %{"id" => id, "role" => role}, socket) do
    user = Accounts.get_user!(id)
    role = Enum.find(User.roles(), &(Atom.to_string(&1) == role))

    case Accounts.update_user_role(user, role) do
      {:ok, user} -> {:noreply, put_user(socket, user)}
      {:error, :last_admin} -> {:noreply, last_admin_error(socket)}
    end
  end

  def handle_event("deactivate", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

    case Accounts.deactivate_user(user) do
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)

        {:noreply,
         socket
         |> put_flash(:info, gettext("%{email} can no longer log in.", email: user.email))
         |> put_user(user)}

      {:error, :last_admin} ->
        {:noreply, last_admin_error(socket)}
    end
  end

  def handle_event("reactivate", %{"id" => id}, socket) do
    {:ok, user} = id |> Accounts.get_user!() |> Accounts.reactivate_user()
    {:noreply, put_user(socket, user)}
  end

  defp refresh(socket, user), do: put_user(socket, user)

  # Reloaded with the identities, for the login column
  defp put_user(socket, user),
    do: stream_insert(socket, :users, Accounts.get_user_with_identities!(user.id))

  defp clear_link_for(socket, user) do
    case socket.assigns.invite_link do
      %{user: %{id: id}} when id == user.id -> assign(socket, :invite_link, nil)
      _ -> socket
    end
  end

  defp last_admin_error(socket) do
    put_flash(socket, :error, gettext("TestFleet needs at least one active admin."))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:users}>
      <div id="users" class="space-y-8">
        <.page_header
          title={gettext("Users")}
          description={
            gettext("Admins manage users, registries, and notifications. Members do everything else.")
          }
        />

        <.panel id="invite" title={gettext("Invite someone")}>
          <.form
            for={@invite_form}
            id="invite-form"
            phx-change="validate_invite"
            phx-submit="invite"
            class="flex flex-wrap items-start gap-3 p-5"
          >
            <div class="min-w-56 flex-1">
              <.input
                field={@invite_form[:email]}
                type="email"
                placeholder={gettext("name@example.com")}
                aria-label={gettext("Email")}
                autocomplete="off"
                required
              />
            </div>
            <div class="w-36">
              <.input
                field={@invite_form[:role]}
                type="select"
                aria-label={gettext("Role")}
                options={Enum.map(User.roles(), &{Layouts.role_label(&1), &1})}
              />
            </div>
            <.button id="invite-submit" variant="primary" phx-disable-with={gettext("Inviting…")}>
              <.icon name="hero-envelope-mini" class="size-4" /> {gettext("Invite")}
            </.button>
          </.form>

          <div
            :if={@invite_link}
            id="invite-link"
            class="space-y-3 border-t border-base-300 bg-primary/5 px-5 py-4"
          >
            <div class="flex items-start justify-between gap-3">
              <p class="text-sm">
                <%= if @invite_link.emailed? do %>
                  {gettext("Invitation emailed to %{email}. You can also share the link yourself:",
                    email: @invite_link.user.email
                  )}
                <% else %>
                  {gettext("Send this link to %{email}. It is shown only now and valid for 7 days.",
                    email: @invite_link.user.email
                  )}
                <% end %>
              </p>
              <.button
                id="dismiss-invite-link"
                variant="ghost"
                size="sm"
                phx-click="dismiss_link"
                aria-label={gettext("Dismiss")}
              >
                <.icon name="hero-x-mark-mini" class="size-4" />
              </.button>
            </div>
            <.copy_field id="invite-link-url" value={@invite_link.url} />
          </div>
        </.panel>

        <div class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 text-xs font-medium tracking-wide text-base-content/60 uppercase">
              <tr>
                <th class="px-5 py-3 font-medium">{gettext("Email")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Role")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Status")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Login")}</th>
                <th class="px-5 py-3 font-medium">{gettext("Last login")}</th>
                <th class="px-5 py-3"><span class="sr-only">{gettext("Actions")}</span></th>
              </tr>
            </thead>
            <tbody id="user-list" phx-update="stream" class="divide-y divide-base-300">
              <tr
                :for={{id, user} <- @streams.users}
                id={id}
                class="transition-colors duration-150 hover:bg-base-200/40"
              >
                <td class="px-5 py-3 font-medium">
                  {user.email}
                  <.badge :if={user.id == @current_scope.user.id} class="ml-1.5">
                    {gettext("you")}
                  </.badge>
                </td>
                <td class="px-5 py-3">
                  <.badge tone={if(user.role == :admin, do: :primary, else: :neutral)}>
                    {Layouts.role_label(user.role)}
                  </.badge>
                </td>
                <td class="px-5 py-3">
                  <.user_status id={"user-status-#{user.id}"} status={User.status(user)} />
                </td>
                <td id={"user-logins-#{user.id}"} class="px-5 py-3">
                  <div class="flex flex-wrap gap-1">
                    <.badge :if={user.hashed_password}>{gettext("Password")}</.badge>
                    <.badge :if={user.identities != []} tone={:primary}>{@provider_name}</.badge>
                    <.badge :if={user.api_token_count > 0} id={"user-api-tokens-#{user.id}"}>
                      {ngettext("1 API token", "%{count} API tokens", user.api_token_count)}
                    </.badge>
                  </div>
                </td>
                <td class="px-5 py-3 text-xs text-base-content/60">
                  <.local_time :if={user.last_login_at} at={user.last_login_at} timezone={@timezone} />
                  <span :if={!user.last_login_at}>–</span>
                </td>
                <td class="w-0 px-5 py-2">
                  <div
                    :if={user.id != @current_scope.user.id}
                    class="flex items-center justify-end gap-1 whitespace-nowrap"
                  >
                    <%= case User.status(user) do %>
                      <% :invited -> %>
                        <.button
                          id={"renew-#{user.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="renew"
                          phx-value-id={user.id}
                        >
                          {gettext("New link")}
                        </.button>
                        <.button
                          id={"revoke-#{user.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="revoke"
                          phx-value-id={user.id}
                          data-confirm={
                            gettext("Revoke the invitation for %{email}?", email: user.email)
                          }
                        >
                          {gettext("Revoke")}
                        </.button>
                      <% :active -> %>
                        <.button
                          id={"role-#{user.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="set_role"
                          phx-value-id={user.id}
                          phx-value-role={if(user.role == :admin, do: "member", else: "admin")}
                        >
                          {if(user.role == :admin,
                            do: gettext("Make member"),
                            else: gettext("Make admin")
                          )}
                        </.button>
                        <.button
                          id={"deactivate-#{user.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="deactivate"
                          phx-value-id={user.id}
                          data-confirm={
                            gettext("Deactivate %{email}? They are logged out and cannot log in.",
                              email: user.email
                            )
                          }
                        >
                          {gettext("Deactivate")}
                        </.button>
                      <% :deactivated -> %>
                        <.button
                          id={"reactivate-#{user.id}"}
                          variant="ghost"
                          size="sm"
                          phx-click="reactivate"
                          phx-value-id={user.id}
                        >
                          {gettext("Reactivate")}
                        </.button>
                    <% end %>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :status, :atom, required: true

  defp user_status(assigns) do
    ~H"""
    <span id={@id} class="inline-flex items-center gap-1.5 text-xs font-medium">
      <span class={[
        "size-1.5 rounded-full",
        @status == :active && "bg-success",
        @status == :invited && "bg-warning",
        @status == :deactivated && "bg-base-content/30"
      ]} />
      {user_status_label(@status)}
    </span>
    """
  end

  defp user_status_label(:active), do: gettext("Active")
  defp user_status_label(:invited), do: gettext("Invited")
  defp user_status_label(:deactivated), do: gettext("Deactivated")
end
