defmodule TestFleet.RegistriesFixtures do
  @moduledoc """
  Test helpers for creating entities via the `TestFleet.Registries` context.
  """

  import TestFleet.OrganizationsFixtures, only: [org_scope: 0, org_scope: 1]

  @doc "A registry of `:organization` (default: the installation's)."
  def registry_fixture(attrs \\ %{}) do
    unique = System.unique_integer([:positive])
    {organization, attrs} = attrs |> Map.new() |> Map.pop(:organization)
    scope = if organization, do: org_scope(organization), else: org_scope()

    {:ok, registry} =
      attrs
      |> Enum.into(%{
        name: "Registry #{unique}",
        host: "registry#{unique}.example.com",
        username: "deploy",
        password: "s3cret-token"
      })
      |> then(&TestFleet.Registries.create_registry(scope, &1))

    registry
  end
end
