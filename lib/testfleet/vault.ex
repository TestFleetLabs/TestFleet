defmodule TestFleet.Vault do
  @moduledoc """
  Encryption at rest for environment variable values, registry passwords, and
  notification secrets. Keys are configured per environment; production reads
  `CLOAK_KEY`.
  """
  use Cloak.Vault, otp_app: :testfleet
end
