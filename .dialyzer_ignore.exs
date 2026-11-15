# Warnings caused by incomplete typespecs in dependencies, not by our code.
[
  # oidcc: :oidcc_authorization.opts() omits `preferred_auth_methods`, which
  # attempt_par/3 reads when the provider offers pushed authorization requests
  # (Keycloak does). Without it, oidcc would pick client_secret_jwt there.
  {"lib/testfleet/accounts/oidc/oidcc_client.ex", :call},
  {"lib/testfleet/accounts/oidc/oidcc_client.ex", :no_return},
  # oidcc: Oidcc.Token.t() types `id` as `Id.t() | none` (the empty type, not the
  # atom :none), but a token response without an ID token has `id: :none`.
  {"lib/testfleet/accounts/oidc/oidcc_client.ex", :pattern_match},
  # Ecto: %Ecto.Multi{} defaults `names` to MapSet.new(), evaluated at compile time,
  # so Multi.new() returns a literal %MapSet{} where the opaque MapSet.t() is
  # expected.
  {"lib/testfleet/notifications.ex", :call_without_opaque}
]
