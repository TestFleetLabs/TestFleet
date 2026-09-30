defmodule TestFleetWeb.UserLive.Settings do
  @moduledoc """
  The user's own settings (Milestone 10, section 9): the linked single sign-on
  account, the password (unless `AUTH_PASSWORD_LOGIN=false`), and the email address
  when SMTP is configured (a change is confirmed by email). Requires sudo mode: a
  login within the last 10 minutes.
  """
  use TestFleetWeb, :live_view

  on_mount {TestFleetWeb.UserAuth, :require_sudo_mode}

  alias TestFleet.Accounts
  alias TestFleet.Accounts.OIDC

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="settings" class="space-y-8">
        <.page_header title={gettext("Settings")} description={@current_email} />

        <.panel :if={@oidc_enabled} id="sso" title={@provider_name} class="max-w-2xl">
          <div class="flex flex-wrap items-center justify-between gap-4 p-5">
            <p :if={@identity} id="sso-linked" class="text-sm">
              {gettext("Linked to %{email}.", email: @identity.email)}
            </p>
            <p :if={!@identity} id="sso-unlinked" class="text-sm text-base-content/60">
              {gettext("Not linked. Link it to log in with %{provider}.", provider: @provider_name)}
            </p>
            <.button
              :if={!@identity}
              id="sso-link"
              variant="primary"
              size="sm"
              href={~p"/auth/oidc/link"}
            >
              {gettext("Link")}
            </.button>
            <.button
              :if={@identity && @can_unlink}
              id="sso-unlink"
              size="sm"
              phx-click="unlink"
              data-confirm={gettext("Unlink %{provider}?", provider: @provider_name)}
            >
              {gettext("Unlink")}
            </.button>
          </div>
        </.panel>

        <.form
          :if={@password_login}
          for={@password_form}
          id="password_form"
          action={~p"/users/update-password"}
          method="post"
          phx-change="validate_password"
          phx-submit="update_password"
          phx-trigger-action={@trigger_submit}
        >
          <.form_card>
            <div>
              <h2 class="text-sm font-semibold">{gettext("Password")}</h2>
              <p class="mt-1 text-sm text-base-content/60">
                {gettext("Changing it logs you out everywhere else.")}
              </p>
            </div>
            <input
              name={@password_form[:email].name}
              type="hidden"
              id="hidden_user_email"
              spellcheck="false"
              value={@current_email}
            />
            <.input
              field={@password_form[:password]}
              type="password"
              label={gettext("New password")}
              hint={gettext("At least 12 characters.")}
              autocomplete="new-password"
              spellcheck="false"
              required
            />
            <.input
              field={@password_form[:password_confirmation]}
              type="password"
              label={gettext("Confirm new password")}
              autocomplete="new-password"
              spellcheck="false"
            />
            <:footer>
              <.button variant="primary" phx-disable-with={gettext("Saving…")}>
                {gettext("Save password")}
              </.button>
            </:footer>
          </.form_card>
        </.form>

        <.form
          :if={@email_enabled}
          for={@email_form}
          id="email_form"
          phx-submit="update_email"
          phx-change="validate_email"
        >
          <.form_card>
            <div>
              <h2 class="text-sm font-semibold">{gettext("Email")}</h2>
              <p class="mt-1 text-sm text-base-content/60">
                {gettext("The new address is confirmed by a link sent to it.")}
              </p>
            </div>
            <.input
              field={@email_form[:email]}
              type="email"
              label={gettext("Email")}
              autocomplete="username"
              spellcheck="false"
              required
            />
            <:footer>
              <.button variant="primary" phx-disable-with={gettext("Sending…")}>
                {gettext("Change email")}
              </.button>
            </:footer>
          </.form_card>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      case Accounts.update_user_email(socket.assigns.current_scope.user, token) do
        {:ok, _user} ->
          put_flash(socket, :info, gettext("Email changed successfully."))

        {:error, _} ->
          put_flash(socket, :error, gettext("Email change link is invalid or it has expired."))
      end

    {:ok, push_navigate(socket, to: ~p"/users/settings")}
  end

  def mount(_params, _session, socket) do
    user = socket.assigns.current_scope.user
    email_changeset = Accounts.change_user_email(user, %{}, validate_unique: false)
    password_changeset = Accounts.change_user_password(user, %{}, hash_password: false)

    socket =
      socket
      |> assign(:page_title, gettext("Settings"))
      |> assign(:current_email, user.email)
      |> assign(:email_enabled, Accounts.email_enabled?())
      |> assign(:password_login, Accounts.password_login_enabled?())
      |> assign(oidc_enabled: OIDC.enabled?(), provider_name: OIDC.provider_name())
      |> assign_identity(user)
      |> assign(:email_form, to_form(email_changeset))
      |> assign(:password_form, to_form(password_changeset))
      |> assign(:trigger_submit, false)

    {:ok, socket}
  end

  @impl true
  def handle_event("validate_email", params, socket) do
    %{"user" => user_params} = params

    email_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_email(user_params, validate_unique: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, email_form: email_form)}
  end

  def handle_event("update_email", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_email(user, user_params) do
      %{valid?: true} = changeset ->
        Accounts.deliver_user_update_email_instructions(
          Ecto.Changeset.apply_action!(changeset, :insert),
          user.email,
          &url(~p"/users/settings/confirm-email/#{&1}")
        )

        info = gettext("A link to confirm your email change has been sent to the new address.")
        {:noreply, socket |> put_flash(:info, info)}

      changeset ->
        {:noreply, assign(socket, :email_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("unlink", _params, socket) do
    user = socket.assigns.current_scope.user

    case Accounts.unlink_identity(user) do
      {:ok, _count} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("%{provider} is unlinked.", provider: OIDC.provider_name()))
         |> assign_identity(user)}

      {:error, :last_login_method} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Set a password first: you would have no way to log in.")
         )}
    end
  end

  def handle_event("validate_password", params, socket) do
    %{"user" => user_params} = params

    password_form =
      socket.assigns.current_scope.user
      |> Accounts.change_user_password(user_params, hash_password: false)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, password_form: password_form)}
  end

  def handle_event("update_password", params, socket) do
    %{"user" => user_params} = params
    user = socket.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)

    case Accounts.change_user_password(user, user_params) do
      %{valid?: true} = changeset ->
        {:noreply, assign(socket, trigger_submit: true, password_form: to_form(changeset))}

      changeset ->
        {:noreply, assign(socket, password_form: to_form(changeset, action: :insert))}
    end
  end

  defp assign_identity(socket, user) do
    assign(socket,
      identity: OIDC.enabled?() && Accounts.get_identity(user),
      can_unlink: Accounts.can_unlink?(user)
    )
  end
end
