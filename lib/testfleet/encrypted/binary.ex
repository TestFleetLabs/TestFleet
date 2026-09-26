defmodule TestFleet.Encrypted.Binary do
  @moduledoc "An Ecto type that stores a string encrypted by `TestFleet.Vault`."
  use Cloak.Ecto.Binary, vault: TestFleet.Vault
end
