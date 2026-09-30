defmodule TestFleetWeb.OIDCController do
  @moduledoc """
  The OIDC flow (Milestone 10, section 7): authorization code with PKCE. The
  request (`state`, `nonce`, PKCE verifier, and mode) waits in the session for the
  callback, which checks `state` before anything else.

  Modes: `login` (the login page), `setup` (first-run setup, with its token),
  `invite` (an invitation link, with its token), and `link` (the settings, in sudo
  mode).
  """
  use TestFleetWeb, :controller

  alias TestFleet.Accounts
  alias TestFleet.Accounts.OIDC
  alias TestFleetWeb.UserAuth

  require Logger

  @session_key :oidc_request

  @doc "Starts a login, or a setup or invitation with their token."
  def start(conn, params) do
    unless OIDC.enabled?(), do: raise(TestFleetWeb.NotFoundError)

    case params do
      %{"mode" => "setup", "token" => token} ->
        unless Accounts.valid_setup_token?(token), do: raise(TestFleetWeb.NotFoundError)
        redirect_to_provider(conn, %{mode: "setup", token: token})

      %{"mode" => "invite", "token" => token} ->
        if Accounts.get_user_by_invitation_token(token) do
          redirect_to_provider(conn, %{mode: "invite", token: token})
        else
          conn
          |> put_flash(:error, gettext("The invitation link is invalid or it has expired."))
          |> redirect(to: ~p"/users/log-in")
        end

      _ ->
        redirect_to_provider(conn, %{mode: "login", token: nil})
    end
  end

  @doc "Links the provider to the logged-in user, from the settings (sudo mode)."
  def link(conn, _params) do
    unless OIDC.enabled?(), do: raise(TestFleetWeb.NotFoundError)

    if Accounts.sudo_mode?(conn.assigns.current_scope.user, -10) do
      redirect_to_provider(conn, %{mode: "link", token: nil})
    else
      conn
      |> put_flash(:error, gettext("You must re-authenticate to access this page."))
      |> put_session(:user_return_to, ~p"/users/settings")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  defp redirect_to_provider(conn, context) do
    request = OIDC.new_request()

    case OIDC.authorize_url(request, callback_url()) do
      {:ok, url} ->
        conn
        |> put_session(@session_key, Map.merge(request, context))
        |> redirect(external: url)

      {:error, reason} ->
        Logger.warning("OIDC: cannot start a login: #{inspect(reason)}")

        conn
        |> put_flash(:error, gettext("Single sign-on is not available right now."))
        |> redirect(to: return_path(context))
    end
  end

  defp callback_url, do: url(~p"/auth/oidc/callback")

  @doc "The provider's redirect back to TestFleet."
  def callback(conn, params) do
    request = get_session(conn, @session_key)
    conn = delete_session(conn, @session_key)

    with {:ok, request} <- check_request(request, params),
         {:ok, code} <- fetch_code(params),
         {:ok, claims} <- OIDC.exchange(code, request, callback_url()),
         {:ok, identity} <- OIDC.identity(claims) do
      finish(conn, request, identity)
    else
      {:error, reason} -> fail(conn, request, reason)
    end
  end

  defp check_request(nil, _params), do: {:error, :no_request}

  defp check_request(request, %{"state" => state}) when is_binary(state) do
    if Plug.Crypto.secure_compare(state, request.state),
      do: {:ok, request},
      else: {:error, :state_mismatch}
  end

  defp check_request(_request, _params), do: {:error, :state_mismatch}

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}

  defp fetch_code(%{"error" => error} = params),
    do: {:error, {:provider, params["error_description"] || error}}

  defp fetch_code(_params), do: {:error, :no_code}

  defp finish(conn, %{mode: "login"}, identity) do
    with {:ok, user} <- Accounts.oidc_login(identity) do
      conn
      |> put_flash(:info, gettext("Welcome back!"))
      |> UserAuth.log_in_user(user)
    else
      {:error, reason} -> fail(conn, %{mode: "login"}, reason)
    end
  end

  defp finish(conn, %{mode: "setup", token: token} = request, identity) do
    with true <- Accounts.valid_setup_token?(token) || {:error, :already_set_up},
         {:ok, user} <- Accounts.oidc_setup(identity) do
      conn
      |> put_flash(:info, gettext("Welcome to TestFleet!"))
      |> UserAuth.log_in_user(user)
    else
      {:error, reason} -> fail(conn, request, reason)
    end
  end

  defp finish(conn, %{mode: "invite", token: token} = request, identity) do
    case Accounts.oidc_accept_invitation(token, identity) do
      {:ok, {user, expired_tokens}} ->
        UserAuth.disconnect_sessions(expired_tokens)

        conn
        |> put_flash(:info, gettext("Welcome to TestFleet!"))
        |> UserAuth.log_in_user(user)

      {:error, reason} ->
        fail(conn, request, reason)
    end
  end

  defp finish(conn, %{mode: "link"} = request, identity) do
    case conn.assigns.current_scope do
      %{user: user} when not is_nil(user) ->
        case Accounts.link_identity(user, identity) do
          {:ok, _identity} ->
            conn
            |> put_flash(:info, gettext("%{provider} is linked.", provider: OIDC.provider_name()))
            |> redirect(to: ~p"/users/settings")

          {:error, reason} ->
            fail(conn, request, reason)
        end

      _ ->
        fail(conn, %{mode: "login"}, :no_request)
    end
  end

  defp fail(conn, request, reason) do
    if reason in [:no_request, :state_mismatch, :no_code] or not is_atom(reason) do
      Logger.warning("OIDC: login failed: #{inspect(reason)}")
    end

    conn
    |> put_flash(:error, error_message(reason))
    |> redirect(to: return_path(request || %{mode: "login"}))
  end

  defp return_path(%{mode: "setup", token: token}), do: ~p"/setup?#{[token: token]}"
  defp return_path(%{mode: "invite", token: token}), do: ~p"/users/invitations/#{token}"
  defp return_path(%{mode: "link"}), do: ~p"/users/settings"
  defp return_path(_request), do: ~p"/users/log-in"

  defp error_message(:deactivated), do: gettext("This account is deactivated.")

  defp error_message(:email_not_verified),
    do:
      gettext(
        "An account with this email already exists. Ask an admin for an invitation link, or log in another way and link %{provider} in your settings.",
        provider: OIDC.provider_name()
      )

  defp error_message(:not_invited),
    do: gettext("You do not have a TestFleet account yet. Ask an admin for an invitation.")

  defp error_message(:domain_not_allowed),
    do:
      gettext(
        "Accounts are created automatically only for %{domains}. Ask an admin for an invitation.",
        domains: Enum.join(OIDC.allowed_domains(), ", ")
      )

  defp error_message(:no_email),
    do:
      gettext(
        "The provider sent no email address (claim \"%{claim}\"). Ask your administrator to check OIDC_EMAIL_CLAIM.",
        claim: OIDC.config()[:email_claim]
      )

  defp error_message(:identity_taken),
    do:
      gettext("This %{provider} account is linked to another TestFleet user.",
        provider: OIDC.provider_name()
      )

  defp error_message(:already_set_up), do: gettext("TestFleet is already set up. Log in instead.")

  defp error_message(:invalid_token),
    do: gettext("The invitation link is invalid or it has expired.")

  defp error_message({:provider, description}),
    do: gettext("The provider refused the login: %{reason}", reason: description)

  defp error_message(reason) when reason in [:no_request, :state_mismatch],
    do: gettext("The login request expired. Please try again.")

  defp error_message(%Ecto.Changeset{}),
    do: gettext("The provider's email address is not valid for a TestFleet account.")

  defp error_message(_reason), do: gettext("Single sign-on failed. Please try again.")
end
