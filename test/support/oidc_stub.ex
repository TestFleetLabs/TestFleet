defmodule TestFleet.OIDCStub do
  @moduledoc """
  A stubbed OIDC provider (Milestone 10, section 13). The authorization URL carries
  the request's `state` and `nonce`; the "authorization code" is the ID token's
  claims, encoded with `code/1`, so each test decides what the provider returns.

  The exchange checks what `oidcc` would: the nonce in the claims must match the
  request's, and the PKCE verifier must be present.
  """
  @behaviour TestFleet.Accounts.OIDC.Client

  @impl true
  def authorize_url(_config, params) do
    query =
      URI.encode_query(%{
        "state" => params.state,
        "nonce" => params.nonce,
        "redirect_uri" => params.redirect_uri,
        "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, params.pkce_verifier))
      })

    {:ok, "https://idp.test/authorize?" <> query}
  end

  @impl true
  def exchange("unavailable", _config, _params), do: {:error, :provider_not_ready}

  def exchange(code, _config, params) do
    claims = code |> Base.url_decode64!(padding: false) |> Jason.decode!()

    cond do
      params.pkce_verifier in [nil, ""] -> {:error, :pkce_verifier_required}
      Map.get(claims, "nonce", params.nonce) != params.nonce -> {:error, :bad_nonce}
      true -> {:ok, claims}
    end
  end

  @doc "The authorization code for these ID token claims."
  def code(claims), do: claims |> Jason.encode!() |> Base.url_encode64(padding: false)
end
