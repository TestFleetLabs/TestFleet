defmodule TestFleet.Accounts.OIDC do
  @moduledoc """
  OIDC login with one provider, discovered from its
  issuer: Entra ID, AD FS, Keycloak, or any other OpenID provider.

  Configured under `config :testfleet, TestFleet.Accounts.OIDC` (from the `OIDC_*`
  variables in `config/runtime.exs`). Without an `:issuer`, OIDC is off. The
  protocol is behind a `TestFleet.Accounts.OIDC.Client`, so tests replace the
  provider.
  """

  @provider TestFleet.Accounts.OIDC.Provider

  @defaults [
    issuer: nil,
    client_id: nil,
    client_secret: nil,
    provider_name: "single sign-on",
    scopes: ["openid", "email", "profile"],
    email_claim: "email",
    provisioning: true,
    allowed_domains: [],
    client: TestFleet.Accounts.OIDC.OidccClient,
    # Tests replace the provider and start no worker.
    start_provider: true,
    # Plain HTTP issuers, for a local Keycloak in development only.
    allow_unsafe_http: false
  ]

  @doc "The configuration, with defaults."
  def config, do: Keyword.merge(@defaults, Application.get_env(:testfleet, __MODULE__, []))

  @doc "Whether OIDC login is configured."
  def enabled?, do: config()[:issuer] not in [nil, ""]

  @doc "The label of the login button."
  def provider_name, do: config()[:provider_name]

  @doc "The provider's issuer, stored on identities."
  def issuer, do: config()[:issuer]

  @doc "Whether unknown users get an account on first login."
  def provisioning?, do: config()[:provisioning]

  @doc "The allowed email domains, lowercase; empty means all."
  def allowed_domains, do: Enum.map(config()[:allowed_domains], &String.downcase/1)

  @doc "The name of the provider configuration worker."
  def provider, do: @provider

  @doc """
  The provider configuration worker, when OIDC is configured. It retries a failed
  discovery with backoff instead of stopping (its default), so an unreachable
  provider cannot take TestFleet down.
  """
  def child_specs do
    config = config()

    if enabled?() and config[:start_provider] do
      [
        {Oidcc.ProviderConfiguration.Worker,
         %{
           issuer: config[:issuer],
           name: @provider,
           backoff_type: :random_exponential,
           backoff_min: :timer.seconds(1),
           backoff_max: :timer.minutes(1),
           provider_configuration_opts: %{
             quirks: %{allow_unsafe_http: config[:allow_unsafe_http]}
           }
         }}
      ]
    else
      []
    end
  end

  @doc """
  A new authorization request: random `state`, `nonce`, and PKCE verifier, kept in
  the session until the callback.
  """
  def new_request do
    %{state: random(), nonce: random(), pkce_verifier: random(48)}
  end

  defp random(bytes \\ 32),
    do: bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "The provider's authorization URL for `request`."
  def authorize_url(request, redirect_uri) do
    config = config()
    config[:client].authorize_url(config, Map.put(request, :redirect_uri, redirect_uri))
  end

  @doc """
  Exchanges the authorization code for the ID token's claims. The client checks
  the token's signature, issuer, audience, and nonce.
  """
  def exchange(code, request, redirect_uri) do
    config = config()
    config[:client].exchange(code, config, Map.put(request, :redirect_uri, redirect_uri))
  end

  @doc """
  The identity in the claims:

      {:ok, %{issuer: _, subject: _, email: _, email_verified: boolean}}
      | {:error, :no_subject | :no_email}
  """
  def identity(claims) do
    email_claim = config()[:email_claim]

    case {claims["sub"], claims[email_claim]} do
      {subject, _} when subject in [nil, ""] ->
        {:error, :no_subject}

      {_, email} when not is_binary(email) or email == "" ->
        {:error, :no_email}

      {subject, email} ->
        {:ok,
         %{
           issuer: issuer(),
           subject: to_string(subject),
           email: String.downcase(email),
           email_verified: claims["email_verified"] in [true, "true"]
         }}
    end
  end

  @doc "Whether the email's domain may get an account on first login."
  def allowed_domain?(email) do
    case allowed_domains() do
      [] -> true
      domains -> (email |> String.split("@") |> List.last() |> String.downcase()) in domains
    end
  end
end
