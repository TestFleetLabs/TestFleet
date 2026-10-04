defmodule TestFleet.OrganizationsFixtures do
  @moduledoc """
  Test helpers for creating organizations through `TestFleet.Organizations`.
  """

  alias TestFleet.Accounts.Scope
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

  @doc "The installation's organization, e.g. for paths."
  def org, do: Organizations.single!()

  @doc """
  A scope within the organization (default: the installation's), without a user:
  for calling the contexts in tests.
  """
  def org_scope(organization \\ Organizations.single!()),
    do: %Scope{organization: organization}
end
