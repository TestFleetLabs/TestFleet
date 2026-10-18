defmodule TestFleet.StatisticsTest do
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.OrganizationsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.SchedulesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Execution.Result
  alias TestFleet.Runs
  alias TestFleet.Statistics

  # A finished run with artifacts of the given sizes and one stored log line.
  defp finished_run(test_definition, environment, status, sizes) do
    run =
      run_fixture(test_definition: test_definition, environment: environment, status: :running)

    :ok =
      Runs.append_log(run.id, [%{sequence: 1, stream: :stdout, content: "hello", timestamp: 1}])

    {:ok, run} =
      Runs.finish(run.id, %Result{
        run_id: run.id,
        status: status,
        finished_at: DateTime.utc_now(),
        artifacts:
          sizes
          |> Enum.with_index()
          |> Enum.map(fn {size, i} -> %{path: "file-#{i}.zip", size_bytes: size} end)
      })

    run
  end

  describe "organization/1" do
    setup do
      project = project_fixture(name: "Shop")
      environment = environment_fixture(project: project)

      %{
        project: project,
        environment: environment,
        traces:
          test_definition_fixture(project: project, name: "Traces", artifact_retention_days: 7),
        smoke: test_definition_fixture(project: project, name: "Smoke")
      }
    end

    test "counts the configuration", context do
      test_definition_fixture(project: context.project, enabled: false)

      schedule_fixture(
        project: context.project,
        test_definition: context.smoke,
        environment: context.environment
      )

      assert Statistics.organization(org_scope()).configuration == %{
               projects: 1,
               test_definitions: {3, 2},
               environments: 1,
               schedules: {1, 1},
               members: 0
             }
    end

    test "counts runs and the storage they hold", context do
      finished_run(context.traces, context.environment, :passed, [1_000, 2_000])
      finished_run(context.traces, context.environment, :failed, [4_000])
      failed = finished_run(context.smoke, context.environment, :error, [500])
      {:ok, _} = Runs.set_pinned(failed, true)
      run_fixture(test_definition: context.smoke, environment: context.environment)

      stats = Statistics.organization(org_scope())

      assert %{total: 4, last_30_days: 4, pinned: 1} = stats.runs
      assert stats.runs.by_status == %{passed: 1, failed: 1, error: 1, queued: 1}

      assert %{bytes: 7_500, files: 4, runs: 3} = stats.storage.artifacts
      assert %{runs: 3, bytes: log_bytes} = stats.storage.logs
      assert log_bytes > 0
      assert stats.storage.artifacts_expired == 0

      assert [
               %{name: "Traces", bytes: 7_000, runs: 2, artifact_retention_days: 7},
               %{name: "Smoke", bytes: 500, runs: 1, artifact_retention_days: nil}
             ] = stats.largest_suites
    end

    test "leaves out other organizations", context do
      finished_run(context.traces, context.environment, :passed, [1_000])

      other = organization_fixture()
      other_project = project_fixture(organization: other)

      finished_run(
        test_definition_fixture(project: other_project),
        environment_fixture(project: other_project),
        :passed,
        [9_000]
      )

      assert %{runs: %{total: 1}, storage: %{artifacts: %{bytes: 1_000}}} =
               Statistics.organization(org_scope())

      assert %{runs: %{total: 1}, storage: %{artifacts: %{bytes: 9_000}}} =
               Statistics.organization(org_scope(other))
    end
  end

  test "installation/0 reads the database's size and tables" do
    assert %{database_bytes: bytes, tables: tables, organizations: organizations} =
             Statistics.installation()

    assert bytes > 0
    assert organizations >= 1
    assert tables != [] and length(tables) <= 10
    assert Enum.all?(tables, &(is_binary(&1.name) and &1.bytes >= 0 and &1.rows >= 0))
  end

  describe "disk_for/2" do
    test "picks the longest mount point holding the path" do
      disks = [
        {~c"/", 100, 40, 60},
        {~c"/var/lib/testfleet", 1_000, 900, 10},
        {~c"/var/lib/testfleet-old", 10, 1, 90}
      ]

      assert %{mount: "/var/lib/testfleet", total_bytes: 1_024_000, available_bytes: 921_600} =
               Statistics.disk_for("/var/lib/testfleet/artifacts", disks)

      assert %{mount: "/"} = Statistics.disk_for("/srv/artifacts", disks)
      assert Statistics.disk_for("/srv", []) == nil
    end

    test "matches Windows drives in either case" do
      assert %{mount: "C:\\"} =
               Statistics.disk_for("c:/data/artifacts", [{~c"C:\\", 100, 50, 50}])
    end
  end

  test "artifacts_disk/0 reports the disk holding the artifacts, once disksup has checked" do
    case Statistics.artifacts_disk() do
      nil -> :ok
      disk -> assert disk.total_bytes >= disk.available_bytes
    end
  end

  test "image_usage/2 sums the images runs recorded, and all of them" do
    images = [
      %{size: 100, digest_references: ["registry.example.com/suite@sha256:aaa"]},
      %{size: 50, digest_references: ["postgres@sha256:bbb"]},
      %{size: 25, digest_references: []}
    ]

    references = MapSet.new(["registry.example.com/suite@sha256:aaa"])

    assert Statistics.image_usage(images, references) == %{
             count: 1,
             bytes: 100,
             host_count: 3,
             host_bytes: 175
           }
  end
end
