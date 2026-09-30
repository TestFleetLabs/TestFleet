defmodule TestFleetWeb.OIDCControllerTest do
  # The OIDC flow against a stubbed provider (Milestone 10, section 7).
  use TestFleetWeb.ConnCase, async: true

  import TestFleet.AccountsFixtures

  alias TestFleet.Accounts
  alias TestFleet.Accounts.User
  alias TestFleet.OIDCStub

  # Starts the flow and returns the conn with the request in its session, and the
  # state and nonce the provider received.
  defp start(conn, path) do
    conn = get(conn, path)
    url = redirected_to(conn)
    assert String.starts_with?(url, "https://idp.test/authorize?")

    %{"state" => state, "nonce" => nonce} =
      url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    {conn, state, nonce}
  end

  defp callback(conn, state, nonce, claims) do
    code = claims |> Map.put_new("nonce", nonce) |> OIDCStub.code()
    get(conn, ~p"/auth/oidc/callback?#{[state: state, code: code]}")
  end

  defp claims(attrs \\ %{}) do
    Enum.into(attrs, %{
      "sub" => "sub-#{System.unique_integer([:positive])}",
      "email" => unique_user_email()
    })
  end

  describe "login" do
    test "creates an account for a new user and logs in", %{conn: conn} do
      {conn, state, nonce} = start(conn, ~p"/auth/oidc")
      claims = claims()
      conn = callback(conn, state, nonce, claims)

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
      assert %User{role: :member} = Accounts.get_user_by_email(claims["email"])
    end

    test "logs in a known identity", %{conn: conn} do
      user = user_fixture()
      claims = claims()
      {:ok, identity} = TestFleet.Accounts.OIDC.identity(claims)
      {:ok, _} = Accounts.link_identity(user, identity)

      {conn, state, nonce} = start(conn, ~p"/auth/oidc")
      conn = callback(conn, state, nonce, claims)

      assert get_session(conn, :user_token)
      assert Accounts.get_user!(user.id).last_login_at
    end

    test "explains why an existing account is not linked by an unverified email", %{conn: conn} do
      user = user_fixture()
      {conn, state, nonce} = start(conn, ~p"/auth/oidc")
      conn = callback(conn, state, nonce, claims(%{"email" => user.email}))

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~
               "Ask an admin for an invitation link"
    end

    test "refuses a wrong state", %{conn: conn} do
      {conn, _state, nonce} = start(conn, ~p"/auth/oidc")
      conn = callback(conn, "forged", nonce, claims())

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "The login request expired"
    end

    test "refuses a callback without a started request", %{conn: conn} do
      conn = callback(conn, "any", "any", claims())

      refute get_session(conn, :user_token)
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "refuses a token with another nonce", %{conn: conn} do
      {conn, state, _nonce} = start(conn, ~p"/auth/oidc")
      conn = callback(conn, state, "replayed", claims())

      refute get_session(conn, :user_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Single sign-on failed"
    end

    test "shows the provider's error", %{conn: conn} do
      {conn, state, _nonce} = start(conn, ~p"/auth/oidc")

      conn =
        get(
          conn,
          ~p"/auth/oidc/callback?#{[state: state, error: "access_denied", error_description: "User is not assigned"]}"
        )

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "User is not assigned"
    end

    test "names the email claim when the token has no email", %{conn: conn} do
      {conn, state, nonce} = start(conn, ~p"/auth/oidc")
      conn = callback(conn, state, nonce, %{"sub" => "abc"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "OIDC_EMAIL_CLAIM"
    end

    test "a request is used once", %{conn: conn} do
      {conn, state, nonce} = start(conn, ~p"/auth/oidc")
      claims = claims()
      conn = callback(conn, state, nonce, claims)
      assert get_session(conn, :user_token)

      conn = conn |> recycle() |> callback(state, nonce, claims)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "The login request expired"
    end
  end

  describe "setup" do
    test "creates the first admin with the identity", %{conn: conn} do
      {conn, state, nonce} =
        start(conn, ~p"/auth/oidc?#{[mode: "setup", token: Accounts.setup_token()]}")

      claims = claims()
      conn = callback(conn, state, nonce, claims)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome to TestFleet!"
      assert %User{role: :admin} = Accounts.get_user_by_email(claims["email"])
    end

    test "is 404 without a valid token", %{conn: conn} do
      assert_error_sent 404, fn ->
        get(conn, ~p"/auth/oidc?#{[mode: "setup", token: "wrong"]}")
      end
    end
  end

  describe "invitation" do
    test "accepts the invitation with the identity, whatever its email", %{conn: conn} do
      {user, token} = invited_user_fixture()
      {conn, state, nonce} = start(conn, ~p"/auth/oidc?#{[mode: "invite", token: token]}")
      conn = callback(conn, state, nonce, claims(%{"email" => "upn@corp.example"}))

      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, :user_token)
      assert User.status(Accounts.get_user!(user.id)) == :active
      assert Accounts.get_identity(user)
    end

    test "an invalid invitation link does not start the flow", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc?#{[mode: "invite", token: "nope"]}")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end

  describe "linking" do
    setup :register_and_log_in_user

    test "links the provider to the logged-in user", %{conn: conn, user: user} do
      {conn, state, nonce} = start(conn, ~p"/auth/oidc/link")
      conn = callback(conn, state, nonce, claims())

      assert redirected_to(conn) == ~p"/users/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "is linked"
      assert Accounts.get_identity(user)
    end

    @tag token_authenticated_at: DateTime.add(DateTime.utc_now(:second), -11, :minute)
    test "requires sudo mode", %{conn: conn} do
      conn = get(conn, ~p"/auth/oidc/link")
      assert redirected_to(conn) == ~p"/users/log-in"
    end
  end
end
