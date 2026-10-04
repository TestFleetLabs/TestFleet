defmodule TestFleet.Accounts.OIDC.Client do
  @moduledoc """
  The OIDC protocol, behind a behaviour so tests can replace the provider.
  `params` carries `redirect_uri`, `state`, `nonce`, and `pkce_verifier`.
  """

  @callback authorize_url(config :: keyword(), params :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @callback exchange(code :: String.t(), config :: keyword(), params :: map()) ::
              {:ok, claims :: map()} | {:error, term()}
end
