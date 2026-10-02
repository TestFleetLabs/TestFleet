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

  describe "create_run/3" do
    test "creates a queued run with the definition's image and command", context do
      Runs.subscribe()

      assert {:ok, %Run{} = run} =
               Runs.create_run(context.test_definition, context.environment)

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

    test "creates an API run with the user and the token", context do
      user = TestFleet.AccountsFixtures.user_fixture()
      {_token, api_token} = TestFleet.AccountsFixtures.api_token_fixture(user, %{name: "deploy"})

      assert {:ok, run} =
               Runs.create_run(context.test_definition, context.environment,
                 trigger: :api,
                 user: user,
                 api_token: api_token
               )

      assert %{trigger: :api, triggered_by_user_id: user_id, api_token: %{name: "deploy"}} = run
      assert user_id == user.id
    end

    test "broadcasts on the run's own topic", context do
      {:ok, run} = Runs.create_run(context.test_definition, context.environment)
      Runs.subscribe(run.id)

      :ok = Runs.cancel_run(run)
      assert_receive {:run_finished, %Run{status: :cancelled}}
    end

    test "rejects a test definition disabled in the meantime", context do
      {:ok, _} =
        TestDefinitions.update_test_definition(context.test_definition, %{enabled: false})

      assert {:error, :test_definition_disabled} =
               Runs.create_run(context.test_definition, context.environment)
    end

    test "rejects an environment of another project", context do
      other = environment_fixture()

      assert {:error, :environment_mismatch} =
               Runs.create_run(context.test_definition, other)
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

      assert [first.id, second.id, other.id] ==
               Enum.map(Runs.list_runs(oldest_first: true), & &1.id)
    end
  end

  describe "dashboard_stats/2" do
    defp run(context, attrs), do: run_fixture([test_definition: context.test_definition] ++ attrs)

    test "counts active and queued runs, and results of today in the time zone", context do
      # 10:00 UTC on Sep 27 is 12:00 in Vienna; the day there began at 22:00 UTC on Sep 26.
      now = ~U[2026-09-27 10:00:00Z]
      today = ~U[2026-09-26 22:30:00.000000Z]
      yesterday = ~U[2026-09-26 21:30:00.000000Z]

      run(context, status: :queued)
      run(context, status: :preparing)
      run(context, status: :running)
      run(context, status: :passed, finished_at: today)
      run(context, status: :passed, finished_at: yesterday)
      run(context, status: :failed, finished_at: today)
      run(context, status: :timeout, finished_at: today)
      run(context, status: :error, finished_at: today)
      run(context, status: :cancelled, finished_at: today)

      assert Runs.dashboard_stats("Europe/Vienna", now) == %{
               running: 2,
               queued: 1,
               passed_today: 1,
               failed_today: 1,
               timeouts_today: 1
             }

      # In UTC, the day began at 00:00 UTC on Sep 27: nothing finished today.
      assert %{passed_today: 0, failed_today: 0} = Runs.dashboard_stats("Etc/UTC", now)
    end

    test "a day without midnight starts when the clock jumps", context do
      # Asia/Beirut skips from 00:00 to 01:00 on the last Sunday of March.
      now = ~U[2026-03-29 10:00:00Z]
      run(context, status: :passed, finished_at: ~U[2026-03-28 22:30:00.000000Z])

      assert %{passed_today: 1} = Runs.dashboard_stats("Asia/Beirut", now)
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

    test "an active run records the request, once, for the reconciler", context do
      run = run_fixture(test_definition: context.test_definition, status: :running)
      Runs.subscribe(run.id)

      # No execution process: the run stays active until the reconciler acts.
      assert :ok = Runs.cancel_run(run)

      assert %{status: :running, cancel_requested_at: %DateTime{} = requested_at} =
               Runs.get_run!(run.id)

      assert_receive {:run_updated, %Run{cancel_requested_at: %DateTime{}}}

      assert :ok = Runs.cancel_run(run)
      assert Runs.get_run!(run.id).cancel_requested_at == requested_at
      refute_receive {:run_updated, _}
    end
  end

  describe "mark_cancelled/1" do
    test "finalizes an active run as cancelled, once", context do
      run = run_fixture(test_definition: context.test_definition, status: :preparing)

      assert {:ok, %Run{status: :cancelled, finished_at: %DateTime{}}} =
               Runs.mark_cancelled(run.id)

      assert Runs.mark_cancelled(run.id) == :error
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
               secret_keys: ["API_TOKEN"],
               registry_auth: %{username: "deploy", password: "registry-password"},
               timeout_seconds: 600,
               cpu_limit: 2.0,
               memory_limit: 1_073_741_824,
               shm_size: 2_147_483_648,
               pull_policy: :auto,
               artifact_path: artifact_path,
               max_artifact_bytes: 524_288_000
             } = request

      assert run_id == run.id
      assert artifact_path == TestFleet.Artifacts.Storage.run_dir(run.id)
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

  describe "append_log/3" do
    setup context do
      %{run: run_fixture(test_definition: context.test_definition, status: :running)}
    end

    defp line(sequence, content, stream \\ :stdout),
      do: %{sequence: sequence, stream: stream, content: content, timestamp: 1_000 + sequence}

    defp stored(run), do: run |> Runs.list_log_tail(1_000) |> Enum.map(&{&1.sequence, &1.content})

    test "stores the lines, advances the run, and broadcasts the batch", %{run: run} do
      Runs.subscribe(run.id)

      :ok = Runs.append_log(run.id, [line(1, "starting"), line(2, "warning", :stderr)])

      assert [
               %{sequence: 1, stream: :stdout},
               %{sequence: 2, stream: :stderr, content: "warning"}
             ] =
               Runs.list_log_tail(run, 10)

      assert %{last_log_sequence: 2, last_log_timestamp: 1_002, log_bytes: 15} =
               Runs.get_run!(run.id)

      assert_receive {:run_output, [%{sequence: 1, content: "starting"}, %{sequence: 2}]}
    end

    test "records the newest timestamp, which is not always the last line's", %{run: run} do
      lines = [
        %{line(1, "err", :stderr) | timestamp: 5_000},
        %{line(2, "out") | timestamp: 4_000}
      ]

      :ok = Runs.append_log(run.id, lines)

      assert %{last_log_sequence: 2, last_log_timestamp: 5_000} = Runs.get_run!(run.id)
    end

    test "is not broadcast on the global topic", %{run: run} do
      Runs.subscribe()
      :ok = Runs.append_log(run.id, [line(1, "x")])
      refute_receive {:run_output, _}
    end

    test "replaces NUL bytes, which PostgreSQL cannot store", %{run: run} do
      :ok = Runs.append_log(run.id, [line(1, "a" <> <<0>> <> "b")])
      assert [{1, "a�b"}] = stored(run)
    end

    test "skips lines stored before, e.g. read again after a reattach", %{run: run} do
      :ok = Runs.append_log(run.id, [line(1, "one"), line(2, "two")])
      :ok = Runs.append_log(run.id, [line(2, "two"), line(3, "three")])

      assert [{1, "one"}, {2, "two"}, {3, "three"}] = stored(run)
      assert %{last_log_sequence: 3, log_bytes: 11} = Runs.get_run!(run.id)
    end

    test "stops storing at the log limit, but keeps broadcasting", %{run: run} do
      Runs.subscribe(run.id)
      limit = [max_log_bytes: 10]

      :ok = Runs.append_log(run.id, [line(1, "12345"), line(2, "1234"), line(3, "123")], limit)
      # Would fit the remaining byte, but the log is already truncated.
      :ok = Runs.append_log(run.id, [line(4, "1")], limit)

      assert [{1, "12345"}, {2, "1234"}] = stored(run)

      assert %{log_truncated: true, log_bytes: 9, last_log_sequence: 4} =
               Runs.get_run!(run.id)

      assert_receive {:run_output, [_, _, %{sequence: 3}]}
      assert_receive {:run_output, [%{sequence: 4}]}
    end

    test "list_log_tail/2 returns the last lines in order", %{run: run} do
      :ok = Runs.append_log(run.id, for(n <- 1..5, do: line(n, "line #{n}")))

      assert [{4, "line 4"}, {5, "line 5"}] =
               run |> Runs.list_log_tail(2) |> Enum.map(&{&1.sequence, &1.content})
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
