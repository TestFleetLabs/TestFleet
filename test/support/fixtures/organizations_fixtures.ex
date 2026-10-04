defmodule TestFleet.OrganizationsFixtures do
  @moduledoc """
  Test helpers for creating organizations through `TestFleet.Organizations`.
  """

  alias TestFleet.Organizations

  @doc """
  An organization. Slugs are unique per test, so concurrent tests never wait on
  each other's uncommitted rows.
  """
  def organization_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, organization} =
      attrs
      |> Enum.into(%{name: "Org #{n}", slug: "org-#{n}"})
      |> Organizations.create_organization()

    organization
  end
end
