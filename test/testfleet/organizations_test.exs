defmodule TestFleet.OrganizationsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.AccountsFixtures
  import TestFleet.OrganizationsFixtures

  alias TestFleet.Accounts.Scope
  alias TestFleet.Organizations
  alias TestFleet.Organizations.{Membership, Organization}

  describe "organizations" do
    test "the slug is generated from the name, and unique" do
      assert {:ok, %Organization{slug: "acme-inc"}} =
               Organizations.create_organization(%{name: "ACME Inc."})

      assert {:error, changeset} = Organizations.create_organization(%{name: "Acme Inc"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "top-level path segments are reserved" do
      for slug <- ~w(users api setup runs) do
        assert {:error, changeset} = Organizations.create_organization(%{name: "X", slug: slug})
        assert %{slug: ["is reserved"]} = errors_on(changeset)
      end
    end

    test "single/0 is the installation's organization", %{organization: organization} do
      assert Organizations.single().id == organization.id
      assert Organizations.single!().id == organization.id
    end

    @tag :no_organization
    test "single/0 is nil before the first-run setup" do
      refute Organizations.single()
      assert_raise Ecto.NoResultsError, fn -> Organizations.single!() end
    end
  end

  describe "memberships" do
    test "put_membership/3 adds a member, and changes the role of an existing one", %{
      organization: organization
    } do
      user = user_fixture()
      other = organization_fixture()

      assert {:ok, %Membership{role: :admin}} = Organizations.put_membership(user, other, :admin)

      assert {:ok, %Membership{role: :member}} =
               Organizations.put_membership(user, other, :member)

      assert [:member, :member] =
               user |> Organizations.list_memberships() |> Enum.map(& &1.role)

      assert Organizations.get_membership(user, organization).role == :member
      assert Organizations.get_membership(user, other).role == :member
    end
  end

  describe "scope" do
    test "carries the organization and the user's role in it", %{organization: organization} do
      admin = admin_fixture()
      scope = Scope.for_user(admin)

      assert scope.organization.id == organization.id
      assert Scope.role(scope) == :admin
      assert Scope.admin?(scope)
      refute user_fixture() |> Scope.for_user() |> Scope.admin?()
    end

    test "without a membership there is no role", %{organization: organization} do
      scope = Scope.put_organization(%Scope{user: user_fixture()}, organization_fixture())

      refute Scope.role(scope)
      refute Scope.admin?(scope)
      assert Organizations.get_membership(scope.user, organization)
    end
  end
end
