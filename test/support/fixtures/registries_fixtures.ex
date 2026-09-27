defmodule TestFleet.RegistriesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Registries` context.
  """

  def registry_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])

    {:ok, registry} =
      attrs
      |> Enum.into(%{
        name: "Registry #{unique}",
        host: "registry#{unique}.example.com",
        username: "deploy",
        password: "s3cret-token"
      })
      |> TestFleet.Registries.create_registry()

    registry
  end
end
