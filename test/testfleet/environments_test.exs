defmodule TestFleet.EnvironmentsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures

  alias TestFleet.Environments
  alias TestFleet.Environments.{Environment, Variable}

  describe "environments" do
    test "create_environment/2 generates the slug and defaults to one run at a time" do
      project = project_fixture()

      assert {:ok, %Environment{slug: "production", max_concurrent_runs: 1}} =
               Environments.create_environment(project, %{name: "Production"})
    end

    test "slugs are unique per project, not globally" do
      project = project_fixture()
      other = project_fixture()
      environment_fixture(project: project, name: "Production")

      assert {:error, changeset} = Environments.create_environment(project, %{name: "Production"})
      assert %{slug: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, _} = Environments.create_environment(other, %{name: "Production"})
    end

    test "max_concurrent_runs must be between 1 and 100" do
      project = project_fixture()

      for bad <- [0, 101] do
        assert {:error, changeset} =
                 Environments.create_environment(project, %{name: "P", max_concurrent_runs: bad})

        assert %{max_concurrent_runs: [_]} = errors_on(changeset)
      end
    end

    test "list_environments/1 returns the project's environments with variable counts" do
      project = project_fixture()
      production = environment_fixture(project: project, name: "Production")
      staging = environment_fixture(project: project, name: "staging")
      environment_fixture(name: "Other project")
      variable_fixture(production)
      variable_fixture(production)

      assert [
               %Environment{id: production_id, variable_count: 2},
               %Environment{id: staging_id, variable_count: 0}
             ] = Environments.list_environments(project)

      assert {production_id, staging_id} == {production.id, staging.id}
    end

    test "deleting a project deletes its environments and variables" do
      project = project_fixture()
      environment = environment_fixture(project: project)
      variable = variable_fixture(environment)

      {:ok, _} = TestFleet.Projects.delete_project(project)

      refute Repo.get(Environment, environment.id)
      refute Repo.get(Variable, variable.id)
    end
  end

  describe "variables" do
    setup do
      %{environment: environment_fixture()}
    end

    test "values are encrypted at rest", %{environment: environment} do
      variable = variable_fixture(environment, %{key: "BASE_URL", value: "https://plain.example"})

      %{rows: [[stored]]} =
        Repo.query!("SELECT value_encrypted FROM environment_variables WHERE id = $1", [
          variable.id
        ])

      refute stored =~ "plain.example"
      assert Repo.get!(Variable, variable.id).value == "https://plain.example"
    end

    test "keys must be valid environment variable names", %{environment: environment} do
      for bad <- ["1ABC", "BASE-URL", "BASE URL", ""] do
        assert {:error, changeset} =
                 Environments.create_variable(environment, %{key: bad, value: "x"})

        assert %{key: [_]} = errors_on(changeset), "#{inspect(bad)} should be rejected"
      end

      assert {:ok, %Variable{key: "_base_url2"}} =
               Environments.create_variable(environment, %{key: "  _base_url2 ", value: "x"})
    end

    test "the TestFleet_ prefix is reserved, in any case", %{environment: environment} do
      for key <- ["TestFleet_RUN_ID", "TESTFLEET_X", "testfleet_y"] do
        assert {:error, changeset} =
                 Environments.create_variable(environment, %{key: key, value: "x"})

        assert %{key: ["the TestFleet_ prefix is reserved"]} = errors_on(changeset)
      end
    end

    test "keys are unique per environment", %{environment: environment} do
      variable_fixture(environment, %{key: "BASE_URL"})

      assert {:error, changeset} =
               Environments.create_variable(environment, %{key: "BASE_URL", value: "x"})

      assert %{key: ["has already been taken"]} = errors_on(changeset)
    end

    test "non-secret values may be empty", %{environment: environment} do
      assert {:ok, %Variable{value: ""}} =
               Environments.create_variable(environment, %{key: "EMPTY", value: ""})
    end

    test "secrets need at least 6 characters", %{environment: environment} do
      assert {:error, changeset} =
               Environments.create_variable(environment, %{
                 key: "TOKEN",
                 value: "12345",
                 secret: true
               })

      assert %{value: ["secrets need at least 6 characters to be masked in logs"]} =
               errors_on(changeset)

      assert {:ok, _} =
               Environments.create_variable(environment, %{
                 key: "TOKEN",
                 value: "123456",
                 secret: true
               })
    end

    test "making an existing short value secret is validated", %{environment: environment} do
      variable = variable_fixture(environment, %{value: "abc"})

      assert {:error, changeset} = Environments.update_variable(variable, %{secret: true})
      assert %{value: [_]} = errors_on(changeset)
    end

    test "an empty value keeps the current secret", %{environment: environment} do
      variable =
        variable_fixture(environment, %{key: "TOKEN", value: "s3cret-value", secret: true})

      assert {:ok, updated} =
               Environments.update_variable(variable, %{key: "API_TOKEN", value: ""})

      assert updated.key == "API_TOKEN"
      assert Repo.get!(Variable, variable.id).value == "s3cret-value"

      assert {:ok, _} = Environments.update_variable(variable, %{value: "new-s3cret"})
      assert Repo.get!(Variable, variable.id).value == "new-s3cret"
    end

    test "a secret becomes non-secret only with a new value", %{environment: environment} do
      variable = variable_fixture(environment, %{value: "s3cret-value", secret: true})

      assert {:error, changeset} =
               Environments.update_variable(variable, %{secret: false, value: ""})

      assert %{value: ["enter a new value to make this variable non-secret"]} =
               errors_on(changeset)

      assert {:ok, %Variable{secret: false}} =
               Environments.update_variable(variable, %{secret: false, value: "public"})
    end

    test "redact/1 removes secret values only", %{environment: environment} do
      secret = variable_fixture(environment, %{value: "s3cret-value", secret: true})
      plain = variable_fixture(environment, %{value: "visible"})

      assert Environments.redact(secret).value == nil
      assert Environments.redact(plain).value == "visible"
    end

    test "the value is redacted from inspect output", %{environment: environment} do
      variable = variable_fixture(environment, %{value: "s3cret-value", secret: true})
      refute inspect(variable) =~ "s3cret-value"
    end
  end
end
