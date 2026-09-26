defmodule TestFleet.Vault do
  @moduledoc """
  Encryption at rest for environment variable values and registry passwords
  (main spec section 36). Keys are configured per environment; production reads
  `CLOAK_KEY`.
  """
  use Cloak.Vault, otp_app: :testfleet
end
