defmodule TestFleetWeb.UserLive.Invitation do
  @moduledoc """
  An invitation link (Milestone 10, section 4): the invited user chooses a password
  and is logged in. The release command's links for a lost admin account open here
  too, for an existing user.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Accounts
  alias TestFleetWeb.UserAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title={gettext("Choose your password")}
      subtitle={@user.email}
    >
      <.form
        for={@form}
        id="invitation-form"
        action={~p"/users/log-in?_action=welcome"}
        method="post"
        phx-change="validate"
        phx-submit="save"
        phx-trigger-action={@trigger_submit}
        class="space-y-4"
      >
        <input type="hidden" name="user[email]" value={@user.email} />
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          hint={gettext("At least 12 characters.")}
          autocomplete="new-password"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={gettext("Confirm password")}
          autocomplete="new-password"
          required
        />
        <.button
          id="invitation-submit"
          variant="primary"
          phx-disable-with={gettext("Saving…")}
          class="w-full"
        >
          {gettext("Save password and log in")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_invitation_token(token) do
      {:ok,
       socket
       |> assign(:page_title, gettext("Choose your password"))
       |> assign(user: user, token: token, trigger_submit: false)
       |> assign(:form, to_form(Accounts.change_user_password(user, %{}, hash_password: false)))}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("The invitation link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    form =
      socket.assigns.user
      |> Accounts.change_user_password(params, hash_password: false)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.accept_invitation(socket.assigns.token, params) do
      # The form posts the email and password to the session controller, which logs in.
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)
        form = user |> Accounts.change_user_password(params, hash_password: false) |> to_form()
        {:noreply, assign(socket, form: form, trigger_submit: true)}

      {:error, :invalid_token} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("The invitation link is invalid or it has expired."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end
end
