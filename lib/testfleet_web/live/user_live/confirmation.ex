defmodule TestFleetWeb.UserLive.Confirmation do
  @moduledoc """
  The page a magic link opens. Only active users get magic links, so there is
  nothing to confirm: the button logs in.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth flash={@flash} title={gettext("Welcome back")} subtitle={@user.email}>
      <.form
        for={@form}
        id="login_form"
        phx-submit="submit"
        action={~p"/users/log-in"}
        phx-trigger-action={@trigger_submit}
        class="space-y-3"
      >
        <input type="hidden" name={@form[:token].name} value={@form[:token].value} />
        <%= if @current_scope do %>
          <.button variant="primary" phx-disable-with={gettext("Logging in…")} class="w-full">
            {gettext("Log in")}
          </.button>
        <% else %>
          <.button
            variant="primary"
            name={@form[:remember_me].name}
            value="true"
            phx-disable-with={gettext("Logging in…")}
            class="w-full"
          >
            {gettext("Log in and stay logged in")}
          </.button>
          <.button phx-disable-with={gettext("Logging in…")} class="w-full">
            {gettext("Log in only this time")}
          </.button>
        <% end %>
      </.form>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    if user = Accounts.get_user_by_magic_link_token(token) do
      form = to_form(%{"token" => token}, as: "user")

      {:ok,
       socket
       |> assign(:page_title, gettext("Log in"))
       |> assign(user: user, form: form, trigger_submit: false), temporary_assigns: [form: nil]}
    else
      {:ok,
       socket
       |> put_flash(:error, gettext("The login link is invalid or it has expired."))
       |> push_navigate(to: ~p"/users/log-in")}
    end
  end

  @impl true
  def handle_event("submit", %{"user" => params}, socket) do
    {:noreply, assign(socket, form: to_form(params, as: "user"), trigger_submit: true)}
  end
end
