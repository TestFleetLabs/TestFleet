defmodule TestFleet.RunsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Environments, Projects, Runs, TestDefinitions}
  alias TestFleet.Runs.Run

  setup do
    project = project_fixture()

    %{
      project: project,
      test_definition:
        test_definition_fixture(project: project, image: "e2e:1.17", command: ["./run.sh", "-v"]),
      environment: environment_fixture(project: project)
    }
  end

  describe "create_manual_run/2" do
    test "creates a queued run with the definition's image and command", context do
      Runs.subscribe()

      assert {:ok, %Run{} = run} =
               Runs.create_manual_run(context.test_definition, context.environment)

      assert %{
               status: :queued,
               trigger: :manual,
               image: "e2e:1.17",
               command: ["./run.sh", "-v"],
               started_at: nil,
               finished_at: nil
             } = run

      assert %DateTime{} = run.queued_at
      assert run.test_definition.project.id == context.project.id
      assert run.environment.id == context.environment.id

      run_id = run.id
      assert_receive {:run_created, %Run{id: ^run_id}}
    end

    test "broadcasts on the run's own topic", context do
      {:ok, run} = Runs.create_manual_run(context.test_definition, context.environment)
      Runs.subscribe(run.id)

      :ok = Runs.cancel_run(run)
      assert_receive {:run_finished, %Run{status: :cancelled}}
    end

    test "rejects a test definition disabled in the meantime", context do
      {:ok, _} =
        TestDefinitions.update_test_definition(context.test_definition, %{enabled: false})

      assert {:error, :test_definition_disabled} =
               Runs.create_manual_run(context.test_definition, context.environment)
    end

    test "rejects an environment of another project", context do
      other = environment_fixture()

      assert {:error, :environment_mismatch} =
               Runs.create_manual_run(context.test_definition, other)
    end
  end

  describe "list_runs/1" do
    test "returns runs newest first, filtered and limited", context do
      first = run_fixture(test_definition: context.test_definition, status: :passed)
      second = run_fixture(test_definition: context.test_definition)
      other = run_fixture()

      assert [other.id, second.id, first.id] == Enum.map(Runs.list_runs(), & &1.id)
      assert [other.id] == Enum.map(Runs.list_runs(limit: 1), & &1.id)

      assert [second.id, first.id] ==
               Enum.map(Runs.list_runs(project: context.project), & &1.id)

      assert [second.id, first.id] ==
               Enum.map(Runs.list_runs(test_definition: context.test_definition), & &1.id)

      assert [first.id] ==
               Enum.map(Runs.list_runs(project: context.project, statuses: [:passed]), & &1.id)
    end
  end

  describe "cancel_run/1" do
    test "cancels a queued run, once", context do
      run = run_fixture(test_definition: context.test_definition)
      Runs.subscribe(run.id)

      assert :ok = Runs.cancel_run(run)
      assert %{status: :cancelled, finished_at: %DateTime{}} = cancelled = Runs.get_run!(run.id)
      assert_receive {:run_finished, %Run{status: :cancelled}}

      assert :ok = Runs.cancel_run(run)
      assert Runs.get_run!(run.id).finished_at == cancelled.finished_at
      refute_receive {:run_finished, _}
    end

    test "leaves a finished run alone", context do
      run = run_fixture(test_definition: context.test_definition, status: :passed)

      assert :ok = Runs.cancel_run(run)
      assert %{status: :passed} = Runs.get_run!(run.id)
    end

    test "an active run without an execution process stays as it is", context do
      run = run_fixture(test_definition: context.test_definition, status: :running)

      assert :ok = Runs.cancel_run(run)
      assert %{status: :running} = Runs.get_run!(run.id)
    end
  end

  describe "build_request/1" do
    test "combines the run, test definition, environment, and registry", context do
      {:ok, test_definition} =
        TestDefinitions.update_test_definition(context.test_definition, %{
          image: "registry.company.com/customer-a/e2e:1.17",
          timeout_seconds: 600,
          cpu_limit: 2.0,
          memory_limit: 1024 * 1024 * 1024
        })

      environment = environment_fixture(project: context.project, name: "Production")
      variable_fixture(environment, %{key: "BASE_URL", value: "https://example.com"})
      variable_fixture(environment, %{key: "API_TOKEN", value: "s3cret-token", secret: true})

      TestFleet.RegistriesFixtures.registry_fixture(
        host: "registry.company.com",
        username: "deploy",
        password: "registry-password"
      )

      run = run_fixture(test_definition: test_definition, environment: environment)
      request = Runs.build_request(run)

      assert %TestFleet.Execution.Request{
               run_id: run_id,
               project_id: project_id,
               environment_name: "production",
               image: "registry.company.com/customer-a/e2e:1.17",
               command: ["./run.sh", "-v"],
               environment: %{"BASE_URL" => "https://example.com", "API_TOKEN" => "s3cret-token"},
               secret_values: ["s3cret-token"],
               registry_auth: %{username: "deploy", password: "registry-password"},
               timeout_seconds: 600,
               cpu_limit: 2.0,
               memory_limit: 1_073_741_824,
               shm_size: 2_147_483_648,
               pull_policy: :auto,
               artifact_path: nil
             } = request

      assert run_id == run.id
      assert project_id == context.project.id

      inspected = inspect(request)
      refute inspected =~ "s3cret-token"
      refute inspected =~ "registry-password"
    end

    test "pulls anonymously without a matching registry", context do
      run =
        run_fixture(test_definition: context.test_definition, environment: context.environment)

      assert %{registry_auth: nil, environment: %{}} = Runs.build_request(run)
    end

    test "uses the image copied at creation, not the edited one", context do
      run =
        run_fixture(test_definition: context.test_definition, environment: context.environment)

      {:ok, _} =
        TestDefinitions.update_test_definition(context.test_definition, %{image: "e2e:2.0"})

      assert %{image: "e2e:1.17"} = Runs.build_request(run)
    end
  end

  describe "deleting configuration with runs" do
    setup context do
      %{
        run:
          run_fixture(test_definition: context.test_definition, environment: context.environment)
      }
    end

    test "a test definition with runs cannot be deleted", context do
      assert Runs.has_runs?(context.test_definition)

      assert {:error, :has_runs} = TestDefinitions.delete_test_definition(context.test_definition)
    end

    test "an environment with runs cannot be deleted", context do
      assert {:error, :has_runs} = Environments.delete_environment(context.environment)
    end

    test "a project with runs cannot be deleted", context do
      assert {:error, :has_runs} = Projects.delete_project(context.project)
    end

    test "configuration without runs can still be deleted", context do
      unused = test_definition_fixture(project: context.project)
      refute Runs.has_runs?(unused)
      assert {:ok, _} = TestDefinitions.delete_test_definition(unused)
    end
  end
end
