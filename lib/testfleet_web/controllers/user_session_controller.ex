defmodule TestFleetWeb.UserSessionController do
  use TestFleetWeb, :controller

  alias TestFleet.Accounts
  alias TestFleetWeb.{RateLimit, UserAuth}

  # Password attempts per email: slows guessing down without locking anyone out
  # for long. Magic links and single sign-on are not affected.
  @login_attempts 10
  @login_window :timer.minutes(10)

  # After the first-run setup or accepting an invitation
  def create(conn, %{"_action" => "welcome"} = params) do
    create(conn, params, gettext("Welcome to TestFleet!"))
  end

  def create(conn, params) do
    create(conn, params, gettext("Welcome back!"))
  end

  # "SSO button only": no password or magic-link login
  defp create(conn, params, info) do
    if Accounts.password_login_enabled?() do
      create_session(conn, params, info)
    else
      conn
      |> put_flash(:error, gettext("Log in with single sign-on."))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  # magic link login
  defp create_session(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, gettext("The link is invalid or it has expired."))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create_session(
         conn,
         %{"user" => %{"email" => email, "password" => password} = user_params},
         info
       )
       when is_binary(email) and is_binary(password) do
    # Per email, registered or not, so the answer does not tell which it is. Per
    # address would count everybody behind the reverse proxy as one.
    with :ok <- RateLimit.hit({:login, login_key(email)}, @login_attempts, @login_window),
         %Accounts.User{} = user <- Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      {:error, :rate_limited} ->
        conn
        |> put_flash(:error, gettext("Too many login attempts. Try again in a few minutes."))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")

      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      nil ->
        conn
        |> put_flash(:error, gettext("Invalid email or password"))
        |> put_flash(:email, String.slice(email, 0, 160))
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # A request without the form's fields
  defp create_session(conn, _params, _info) do
    conn
    |> put_flash(:error, gettext("Invalid email or password"))
    |> redirect(to: ~p"/users/log-in")
  end

  defp login_key(email), do: email |> String.trim() |> String.downcase() |> String.slice(0, 160)

  def update_password(conn, %{"user" => user_params} = params) do
    user = conn.assigns.current_scope.user
    true = Accounts.sudo_mode?(user)
    {:ok, {_user, expired_tokens}} = Accounts.update_user_password(user, user_params)

    # disconnect all existing LiveViews with old sessions
    UserAuth.disconnect_sessions(expired_tokens)

    conn
    |> put_session(:user_return_to, ~p"/users/settings")
    |> create(params, gettext("Password updated successfully!"))
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, gettext("Logged out successfully."))
    |> UserAuth.log_out_user()
  end
end
