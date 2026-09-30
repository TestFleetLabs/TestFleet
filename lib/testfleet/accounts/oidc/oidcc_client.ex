defmodule TestFleet.Accounts.OIDC.OidccClient do
  @moduledoc """
  The OIDC protocol with `oidcc`: authorization code with PKCE. `oidcc` validates
  the ID token (signature, issuer, audience, expiry, nonce) and refreshes the
  provider's keys for an unknown key id.
  """
  @behaviour TestFleet.Accounts.OIDC.Client

  alias TestFleet.Accounts.OIDC

  # TestFleet's client authenticates with a client secret. oidcc would otherwise
  # prefer client_secret_jwt where the provider offers it, which a client configured
  # for a plain secret rejects (Keycloak does, for example).
  @auth_methods [:client_secret_basic, :client_secret_post]

  @impl true
  def authorize_url(config, params) do
    opts = %{
      redirect_uri: params.redirect_uri,
      state: params.state,
      nonce: params.nonce,
      pkce_verifier: params.pkce_verifier,
      scopes: config[:scopes],
      preferred_auth_methods: @auth_methods
    }

    with {:ok, url} <-
           Oidcc.create_redirect_url(
             OIDC.provider(),
             config[:client_id],
             config[:client_secret],
             opts
           ) do
      {:ok, IO.iodata_to_binary(url)}
    end
  end

  @impl true
  def exchange(code, config, params) do
    opts = %{
      redirect_uri: params.redirect_uri,
      nonce: params.nonce,
      pkce_verifier: params.pkce_verifier,
      preferred_auth_methods: @auth_methods
    }

    case Oidcc.retrieve_token(
           code,
           OIDC.provider(),
           config[:client_id],
           config[:client_secret],
           opts
         ) do
      {:ok, %Oidcc.Token{id: %Oidcc.Token.Id{claims: claims}}} -> {:ok, claims}
      {:ok, _token} -> {:error, :no_id_token}
      {:error, reason} -> {:error, reason}
    end
  end
end
