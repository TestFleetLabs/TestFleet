defmodule TestFleetWeb.UserLive.Login do
  @moduledoc """
  The login page (Milestone 10, section 4): email and password, and a magic link
  when SMTP is configured. Also used to re-authenticate for sudo mode.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.auth
      flash={@flash}
      title={if(@current_scope, do: gettext("Confirm it's you"), else: gettext("Log in"))}
      subtitle={
        if(@current_scope,
          do: gettext("Log in again to change sensitive settings."),
          else: gettext("TestFleet accounts are created by invitation.")
        )
      }
    >
      <div class="space-y-6">
        <.form
          :let={f}
          for={@form}
          id="login_form_password"
          action={~p"/users/log-in"}
          phx-submit="submit_password"
          phx-trigger-action={@trigger_submit}
          class="space-y-4"
        >
          <.input
            readonly={!!@current_scope}
            field={f[:email]}
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
            autocomplete="current-password"
            spellcheck="false"
            required
          />
          <label class="flex cursor-pointer items-center gap-2 text-sm text-base-content/70">
            <input type="hidden" name={@form[:remember_me].name} value="false" />
            <input
              type="checkbox"
              id="remember-me"
              name={@form[:remember_me].name}
              value="true"
              class="size-4 rounded border-base-300 accent-primary"
            />
            {gettext("Stay logged in on this device")}
          </label>
          <.button id="login-submit" variant="primary" class="w-full">
            {gettext("Log in")}
          </.button>
        </.form>

        <%= if @email_enabled do %>
          <div class="flex items-center gap-3 text-xs text-base-content/40 uppercase">
            <span class="h-px flex-1 bg-base-300"></span>
            {gettext("or")}
            <span class="h-px flex-1 bg-base-300"></span>
          </div>

          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
            class="space-y-3"
          >
            <input
              :if={@current_scope}
              type="hidden"
              name={f[:email].name}
              value={f[:email].value}
            />
            <.input
              :if={!@current_scope}
              field={f[:email]}
              id="magic-email"
              type="email"
              label={gettext("Email me a login link")}
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.button id="magic-submit" class="w-full">
              <.icon name="hero-envelope-mini" class="size-4" /> {gettext("Send login link")}
            </.button>
          </.form>
        <% end %>
      </div>
    </Layouts.auth>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(:page_title, gettext("Log in"))
     |> assign(form: form, trigger_submit: false, email_enabled: Accounts.email_enabled?())}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if Accounts.email_enabled?() do
      if user = Accounts.get_user_by_email(email) do
        Accounts.deliver_login_instructions(user, &url(~p"/users/log-in/#{&1}"))
      end
    end

    info = gettext("If your email is in our system, you will receive a login link shortly.")

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end
end
