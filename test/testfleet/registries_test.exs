defmodule TestFleet.RegistriesTest do
  use TestFleet.DataCase, async: true

  import TestFleet.RegistriesFixtures

  alias TestFleet.Registries
  alias TestFleet.Registries.Registry

  @valid %{
    name: "Company GitLab",
    host: "registry.company.com",
    username: "deploy",
    password: "s3cret-token"
  }

  describe "create_registry/1" do
    test "stores the password encrypted" do
      assert {:ok, registry} = Registries.create_registry(@valid)
      assert Registries.get_registry!(registry.id).password == "s3cret-token"

      %{rows: [[stored]]} =
        Repo.query!("SELECT password_encrypted FROM registries WHERE id = $1", [registry.id])

      refute stored =~ "s3cret-token"
    end

    test "requires name, host, username, and password" do
      assert {:error, changeset} = Registries.create_registry(%{})

      assert %{name: [_], host: [_], username: [_], password: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "normalizes the host the way image references report it" do
      for {entered, stored} <- [
            {"  Registry.Company.COM ", "registry.company.com"},
            {"index.docker.io", "docker.io"},
            {"localhost:5055", "localhost:5055"},
            {"ghcr.io", "ghcr.io"}
          ] do
        {:ok, registry} = Registries.create_registry(%{@valid | host: entered})
        assert registry.host == stored
      end
    end

    test "rejects hosts with a scheme, a path, or invalid characters" do
      for {host, message} <- [
            {"https://registry.company.com", "enter the host without http:// or https://"},
            {"registry.company.com/team", "enter the host only, without a path"},
            {"registry company.com", "is not a valid host name"},
            {"-registry.com", "is not a valid host name"},
            {"registry.com:", "is not a valid host name"}
          ] do
        assert {:error, changeset} = Registries.create_registry(%{@valid | host: host})
        assert %{host: [^message]} = errors_on(changeset), "#{inspect(host)}"
      end
    end

    test "allows one registry per host" do
      registry_fixture(host: "registry.company.com")

      assert {:error, changeset} = Registries.create_registry(@valid)
      assert %{host: ["already has credentials"]} = errors_on(changeset)
    end
  end

  describe "update_registry/2" do
    test "an empty password keeps the current one" do
      registry = registry_fixture(password: "old-token")

      assert {:ok, _} = Registries.update_registry(registry, %{name: "Renamed", password: ""})

      assert %Registry{name: "Renamed", password: "old-token"} =
               Registries.get_registry!(registry.id)
    end

    test "a new password replaces the current one" do
      registry = registry_fixture(password: "old-token")

      assert {:ok, _} = Registries.update_registry(registry, %{password: "new-token"})
      assert Registries.get_registry!(registry.id).password == "new-token"
    end
  end

  describe "get_registry_for_image/1" do
    test "matches by the host of the image reference" do
      company = registry_fixture(host: "registry.company.com")
      local = registry_fixture(host: "localhost:5055")
      hub = registry_fixture(host: "docker.io")

      assert Registries.get_registry_for_image("registry.company.com/customer-a/e2e:1.17").id ==
               company.id

      assert Registries.get_registry_for_image(
               "localhost:5055/fixture-suite@sha256:" <> String.duplicate("a", 64)
             ).id ==
               local.id

      assert Registries.get_registry_for_image("playwright/e2e:1").id == hub.id
      assert Registries.get_registry_for_image("alpine").id == hub.id
    end

    test "returns nil for unknown hosts and invalid references" do
      registry_fixture(host: "registry.company.com")

      assert Registries.get_registry_for_image("ghcr.io/org/e2e:1") == nil
      assert Registries.get_registry_for_image("e2e:") == nil
    end
  end

  describe "test_connection/2" do
    test "needs complete credentials before it asks Docker" do
      assert {:error, "Enter the host, username, and password first."} =
               Registries.test_connection(%Registry{}, %{"host" => "registry.company.com"})
    end

    test "needs a valid host before it asks Docker" do
      assert {:error, "Fix the host first."} =
               Registries.test_connection(%Registry{}, %{
                 "host" => "https://registry.company.com",
                 "username" => "deploy",
                 "password" => "token"
               })
    end
  end

  test "redact/1 and inspect keep the password out" do
    registry = registry_fixture(password: "s3cret-token")

    assert Registries.redact(registry).password == nil
    refute inspect(registry) =~ "s3cret-token"
  end
end
