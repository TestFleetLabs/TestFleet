defmodule TestFleetWeb.UserLive.Setup do
  @moduledoc """
  First-run setup (Milestone 10, section 4): creates the first admin. Only with the
  one-time token from the log, and only while there is no user; otherwise the page
  does not exist.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title={gettext("Set up TestFleet")}
      subtitle={gettext("Create the first admin. Everyone else is invited from the Users page.")}
    >
      <.form
        for={@form}
        id="setup-form"
        action={~p"/users/log-in?_action=welcome"}
        phx-change="validate"
        phx-submit="save"
        phx-trigger-action={@trigger_submit}
        class="space-y-4"
      >
        <.input
          field={@form[:email]}
          type="email"
          label={gettext("Email")}
          autocomplete="username"
          spellcheck="false"
          required
          phx-mounted={JS.focus()}
        />
        <.input
          field={@form[:password]}
          type="password"
          label={gettext("Password")}
          hint={gettext("At least 12 characters.")}
          autocomplete="new-password"
          required
        />
        <.input
          field={@form[:password_confirmation]}
          type="password"
          label={gettext("Confirm password")}
          autocomplete="new-password"
          required
        />
        <.button
          id="setup-submit"
          variant="primary"
          phx-disable-with={gettext("Creating…")}
          class="w-full"
        >
          {gettext("Create admin")}
        </.button>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    unless Accounts.valid_setup_token?(params["token"]), do: raise(TestFleetWeb.NotFoundError)

    {:ok,
     socket
     |> assign(:page_title, gettext("Set up TestFleet"))
     |> assign(:form, to_form(Accounts.change_setup()))
     |> assign(:trigger_submit, false)}
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    form = params |> Accounts.change_setup() |> to_form(action: :validate)
    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.create_first_admin(params) do
      # The form posts the email and password to the session controller, which logs in.
      {:ok, _user} ->
        form = params |> Accounts.change_setup() |> to_form()
        {:noreply, assign(socket, form: form, trigger_submit: true)}

      {:error, :already_set_up} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("TestFleet is already set up. Log in instead."))
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, action: :insert))}
    end
  end
end
