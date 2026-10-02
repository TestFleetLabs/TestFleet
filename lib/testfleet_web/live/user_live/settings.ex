defmodule TestFleetWeb.UserLive.Settings do
  @moduledoc """
  The user's own settings (Milestone 10, section 9): the linked single sign-on
  account, API tokens (Milestone 11, section 8), the password (unless
  `AUTH_PASSWORD_LOGIN=false`), and the email address when SMTP is configured (a
  change is confirmed by email). Requires sudo mode: a login within the last 10
  minutes.
  """
  use TestFleetWeb, :live_view

  on_mount {TestFleetWeb.UserAuth, :require_sudo_mode}

  alias TestFleet.Accounts
  alias TestFleet.Accounts.{APIToken, OIDC}
  alias TestFleet.Schedules.Timezones

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

        <.panel id="api-tokens" title={gettext("API tokens")} class="max-w-2xl">
          <div class="space-y-4 p-5">
            <p class="text-sm text-base-content/60">
              {gettext(
                "For CI pipelines: a token starts and reads runs as you. Send it as \"Authorization: Bearer <token>\"."
              )}
            </p>
            <.form
              for={@api_token_form}
              id="api-token-form"
              phx-change="validate_api_token"
              phx-submit="create_api_token"
              class="flex flex-wrap items-start gap-3"
            >
              <div class="min-w-48 flex-1">
                <.input
                  field={@api_token_form[:name]}
                  type="text"
                  placeholder={gettext("e.g. GitLab staging deploy")}
                  aria-label={gettext("Name")}
                  autocomplete="off"
                  required
                />
              </div>
              <div class="w-36">
                <.input
                  field={@api_token_form[:expires_in]}
                  type="select"
                  aria-label={gettext("Expires")}
                  options={Enum.map(APIToken.expiries(), &{expiry_label(&1), &1})}
                />
              </div>
              <.button
                id="api-token-submit"
                variant="primary"
                phx-disable-with={gettext("Creating…")}
              >
                <.icon name="hero-key-mini" class="size-4" /> {gettext("New token")}
              </.button>
            </.form>

            <div
              :if={@new_api_token}
              id="new-api-token"
              class="space-y-3 rounded-lg border border-primary/30 bg-primary/5 p-4"
            >
              <div class="flex items-start justify-between gap-3">
                <p class="text-sm">
                  {gettext("Copy the token now. It is not shown again.")}
                </p>
                <.button
                  id="dismiss-new-api-token"
                  variant="ghost"
                  size="sm"
                  phx-click="dismiss_api_token"
                  aria-label={gettext("Dismiss")}
                >
                  <.icon name="hero-x-mark-mini" class="size-4" />
                </.button>
              </div>
              <.copy_field id="new-api-token-value" value={@new_api_token} />
            </div>
          </div>

          <ul
            id="api-token-list"
            phx-update="stream"
            class="divide-y divide-base-300 border-t border-base-300"
          >
            <li id="api-tokens-empty" class="hidden px-5 py-4 text-sm text-base-content/60 only:block">
              {gettext("No tokens yet.")}
            </li>
            <li
              :for={{id, token} <- @streams.api_tokens}
              id={id}
              class="flex items-center justify-between gap-4 px-5 py-3"
            >
              <div class="min-w-0">
                <p class="flex items-center gap-2 text-sm font-medium">
                  <span class="truncate">{token.name}</span>
                  <span class="font-mono text-xs text-base-content/50">tf_…{token.hint}</span>
                  <.badge :if={APIToken.expired?(token, @now)} tone={:warning}>
                    {gettext("Expired")}
                  </.badge>
                </p>
                <p class="mt-0.5 flex flex-wrap gap-x-3 text-xs text-base-content/60">
                  <span>
                    {gettext("Created")}
                    <.local_time at={token.inserted_at} timezone={@timezone} />
                  </span>
                  <span>
                    <%= if token.expires_at do %>
                      {gettext("Expires")}
                      <.local_time at={token.expires_at} timezone={@timezone} />
                    <% else %>
                      {gettext("Never expires")}
                    <% end %>
                  </span>
                  <span>
                    <%= if token.last_used_at do %>
                      {gettext("Last used")}
                      <.local_time at={token.last_used_at} timezone={@timezone} />
                    <% else %>
                      {gettext("Never used")}
                    <% end %>
                  </span>
                </p>
              </div>
              <.button
                id={"revoke-api-token-#{token.id}"}
                variant="ghost"
                size="sm"
                phx-click="revoke_api_token"
                phx-value-id={token.id}
                data-confirm={
                  gettext("Revoke \"%{name}\"? Pipelines using it stop working.", name: token.name)
                }
              >
                {gettext("Revoke")}
              </.button>
            </li>
          </ul>
        </.panel>

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
      |> assign(:timezone, Timezones.default())
      |> assign(:now, DateTime.utc_now())
      |> assign(:api_token_form, to_form(Accounts.change_api_token()))
      |> assign(:new_api_token, nil)
      |> stream(:api_tokens, Accounts.list_api_tokens(socket.assigns.current_scope))

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

  def handle_event("validate_api_token", %{"api_token" => params}, socket) do
    form = params |> Accounts.change_api_token() |> to_form(action: :validate)
    {:noreply, assign(socket, :api_token_form, form)}
  end

  def handle_event("create_api_token", %{"api_token" => params}, socket) do
    scope = socket.assigns.current_scope
    true = Accounts.sudo_mode?(scope.user)

    case Accounts.create_api_token(scope, params) do
      {:ok, {token, api_token}} ->
        {:noreply,
         socket
         |> assign(:new_api_token, token)
         |> assign(:api_token_form, to_form(Accounts.change_api_token()))
         |> stream_insert(:api_tokens, api_token, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, :api_token_form, to_form(changeset, action: :insert))}
    end
  end

  def handle_event("dismiss_api_token", _params, socket) do
    {:noreply, assign(socket, :new_api_token, nil)}
  end

  def handle_event("revoke_api_token", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Accounts.delete_api_token(scope, id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Token revoked."))
         |> stream(:api_tokens, Accounts.list_api_tokens(scope), reset: true)}

      {:error, :not_found} ->
        {:noreply, stream(socket, :api_tokens, Accounts.list_api_tokens(scope), reset: true)}
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

  defp expiry_label("30"), do: gettext("30 days")
  defp expiry_label("90"), do: gettext("90 days")
  defp expiry_label("365"), do: gettext("1 year")
  defp expiry_label("never"), do: gettext("No expiry")

  defp assign_identity(socket, user) do
    assign(socket,
      identity: OIDC.enabled?() && Accounts.get_identity(user),
      can_unlink: Accounts.can_unlink?(user)
    )
  end
end
