defmodule TestFleet.TestDefinitionsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.ProjectsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Projects, TestDefinitions}
  alias TestFleet.TestDefinitions.TestDefinition

  @mib 1024 * 1024

  setup do
    %{project: project_fixture()}
  end

  describe "create_test_definition/2" do
    test "uses the defaults of the spec", %{project: project} do
      assert {:ok, test_definition} =
               TestDefinitions.create_test_definition(project, %{
                 name: "Customer Portal E2E",
                 image: "registry.company.com/customer-a/e2e:1.17"
               })

      assert %TestDefinition{
               slug: "customer-portal-e2e",
               command: [],
               timeout_seconds: 1800,
               cpu_limit: nil,
               memory_limit: nil,
               shm_size_bytes: 2_147_483_648,
               enabled: true
             } = test_definition
    end

    test "requires a name and a valid image reference", %{project: project} do
      assert {:error, changeset} = TestDefinitions.create_test_definition(project, %{})
      assert %{name: [_], image: [_]} = errors_on(changeset)

      for image <- ["e2e:", "registry.company.com/", "e2e@"] do
        assert {:error, changeset} =
                 TestDefinitions.create_test_definition(project, %{name: "Suite", image: image})

        assert %{image: ["is not a valid image reference"]} = errors_on(changeset), image
      end
    end

    test "trims the image", %{project: project} do
      {:ok, test_definition} =
        TestDefinitions.create_test_definition(project, %{name: "Suite", image: "  alpine:3 "})

      assert test_definition.image == "alpine:3"
    end

    test "validates the limits in stored units", %{project: project} do
      attrs = %{name: "Suite", image: "alpine:3"}

      for {field, value} <- [
            timeout_seconds: 0,
            timeout_seconds: 86_401,
            cpu_limit: 0,
            cpu_limit: -1,
            memory_limit: 5 * @mib,
            shm_size_bytes: 0
          ] do
        assert {:error, changeset} =
                 TestDefinitions.create_test_definition(project, Map.put(attrs, field, value))

        assert Map.has_key?(errors_on(changeset), field), "#{field}: #{value}"
      end
    end

    test "slugs are unique per project, not globally", %{project: project} do
      test_definition_fixture(project: project, name: "Smoke")

      assert {:error, changeset} =
               TestDefinitions.create_test_definition(project, %{name: "Smoke", image: "alpine"})

      assert %{slug: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _} =
               TestDefinitions.create_test_definition(project_fixture(), %{
                 name: "Smoke",
                 image: "alpine"
               })
    end
  end

  describe "form fields" do
    test "minutes, MiB, and lines are converted to stored units", %{project: project} do
      {:ok, test_definition} =
        TestDefinitions.create_test_definition(project, %{
          "name" => "Suite",
          "image" => "alpine:3",
          "timeout_minutes" => "45",
          "memory_limit_mib" => "4096",
          "shm_size_mib" => "1024",
          "command_text" => "  ./run-e2e.sh \r\n\n--project\nchromium\n"
        })

      assert test_definition.timeout_seconds == 45 * 60
      assert test_definition.memory_limit == 4096 * @mib
      assert test_definition.shm_size_bytes == 1024 * @mib
      assert test_definition.command == ["./run-e2e.sh", "--project", "chromium"]
    end

    test "empty optional fields clear the limit and the command" do
      test_definition =
        test_definition_fixture(memory_limit: 512 * @mib, command: ["./run.sh"])

      {:ok, test_definition} =
        TestDefinitions.update_test_definition(test_definition, %{
          "memory_limit_mib" => "",
          "command_text" => ""
        })

      assert test_definition.memory_limit == nil
      assert test_definition.command == []
    end

    test "an unchanged form value is still stored" do
      test_definition = test_definition_fixture(timeout_seconds: 600)

      changeset =
        TestDefinitions.change_test_definition(test_definition, %{"timeout_minutes" => "10"})

      assert Ecto.Changeset.get_field(changeset, :timeout_seconds) == 600
      assert changeset.valid?
    end

    test "errors are reported on the form field, in its unit", %{project: project} do
      {:error, changeset} =
        TestDefinitions.create_test_definition(project, %{
          "name" => "Suite",
          "image" => "alpine",
          "timeout_minutes" => "1441",
          "memory_limit_mib" => "5",
          "shm_size_mib" => ""
        })

      assert %{
               timeout_minutes: ["must be less than or equal to 1440"],
               memory_limit_mib: ["must be greater than or equal to 6"],
               shm_size_mib: ["can't be blank"]
             } = errors_on(changeset)
    end

    test "the form shows stored values in form units, rounding the timeout up" do
      test_definition =
        test_definition_fixture(
          timeout_seconds: 90,
          memory_limit: 256 * @mib,
          command: ["npx", "playwright", "test"]
        )

      changeset = TestDefinitions.change_test_definition(test_definition)

      assert Ecto.Changeset.get_field(changeset, :timeout_minutes) == 2
      assert Ecto.Changeset.get_field(changeset, :memory_limit_mib) == 256
      assert Ecto.Changeset.get_field(changeset, :shm_size_mib) == 2048
      assert Ecto.Changeset.get_field(changeset, :command_text) == "npx\nplaywright\ntest"
    end

    test "too many or too long arguments are rejected", %{project: project} do
      attrs = %{"name" => "Suite", "image" => "alpine"}

      {:error, changeset} =
        TestDefinitions.create_test_definition(
          project,
          Map.put(attrs, "command_text", Enum.map_join(1..101, "\n", &"arg#{&1}"))
        )

      assert %{command_text: ["has more than 100 arguments"]} = errors_on(changeset)

      {:error, changeset} =
        TestDefinitions.create_test_definition(
          project,
          Map.put(attrs, "command_text", String.duplicate("x", 4097))
        )

      assert %{command_text: ["has an argument longer than 4096 characters"]} =
               errors_on(changeset)
    end
  end

  test "list_test_definitions/1 lists a project's definitions by name", %{project: project} do
    test_definition_fixture(project: project, name: "smoke")
    test_definition_fixture(project: project, name: "Checkout")
    test_definition_fixture(name: "Elsewhere")

    assert project |> TestDefinitions.list_test_definitions() |> Enum.map(& &1.name) ==
             ["Checkout", "smoke"]
  end

  test "get_test_definition!/2 only finds definitions of the project", %{project: project} do
    other = test_definition_fixture()

    assert_raise Ecto.NoResultsError, fn ->
      TestDefinitions.get_test_definition!(project, other.id)
    end
  end

  test "deleting the project deletes its test definitions", %{project: project} do
    test_definition = test_definition_fixture(project: project)
    {:ok, _} = Projects.delete_project(project)

    refute Repo.get(TestDefinition, test_definition.id)
  end
end
