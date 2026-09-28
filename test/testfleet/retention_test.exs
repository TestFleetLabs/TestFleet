defmodule TestFleet.RetentionTest do
  # Milestone 6 section 8.
  #
  # Not async: the batch test finishes 101 runs, and each is broadcast on the global
  # `runs` topic. Concurrent LiveView tests with capped run lists (the dashboard)
  # would see them push their own runs out.
  use TestFleet.DataCase, async: false

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.{CleanupWorker, Storage}
  alias TestFleet.Execution.Result
  alias TestFleet.Retention
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  @finished_at ~U[2026-06-01 12:00:00.000000Z]

  setup do
    project = project_fixture()

    %{
      project: project,
      test_definition: test_definition_fixture(project: project),
      environment: environment_fixture(project: project)
    }
  end

  # A finished run with one artifact (on disk and as a row) and two log lines.
  defp finished_run(context, status \\ :passed, attrs \\ []) do
    run =
      run_fixture(
        [
          test_definition: context.test_definition,
          environment: context.environment,
          status: :running
        ] ++
          attrs
      )

    file = Path.join(Storage.run_dir(run.id), "screenshots/login.png")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "png")

    :ok =
      Runs.append_log(run.id, [
        %{sequence: 1, stream: :stdout, content: "one", timestamp: 1},
        %{sequence: 2, stream: :stdout, content: "two", timestamp: 2}
      ])

    {:ok, run} =
      Runs.finish(run.id, %Result{
        run_id: run.id,
        status: status,
        finished_at: @finished_at,
        artifacts: [%{path: "screenshots/login.png", size_bytes: 3}]
      })

    run
  end

  defp days_later(days), do: DateTime.add(@finished_at, days, :day)

  defp artifacts?(run),
    do: Artifacts.list_artifacts(run) != [] and File.dir?(Storage.run_dir(run.id))

  defp logs?(run), do: Runs.list_log_tail(run, 10) != []

  test "expires artifacts after 30 days, and logs after 90", context do
    run = finished_run(context)

    assert Retention.run(days_later(29)) == %{artifacts: 0, logs: 0}
    assert artifacts?(run) and logs?(run)

    Runs.subscribe(run.id)
    assert Retention.run(days_later(30)) == %{artifacts: 1, logs: 0}
    refute artifacts?(run)
    refute File.exists?(Storage.run_dir(run.id))
    assert logs?(run)
    assert_receive {:run_updated, %Run{artifacts_expired_at: %DateTime{}}}

    assert %{artifacts_expired_at: expired_at, logs_expired_at: nil} = Runs.get_run!(run.id)
    assert DateTime.compare(expired_at, days_later(30)) == :eq

    assert Retention.run(days_later(90)) == %{artifacts: 0, logs: 1}
    refute logs?(run)
    assert %{logs_expired_at: %DateTime{}} = Runs.get_run!(run.id)

    # Nothing left to do.
    assert Retention.run(days_later(365)) == %{artifacts: 0, logs: 0}
  end

  test "keeps pinned runs until they are unpinned", context do
    run = finished_run(context)
    {:ok, _} = Runs.set_pinned(run, true)

    assert Retention.run(days_later(365)) == %{artifacts: 0, logs: 0}
    assert artifacts?(run) and logs?(run)

    {:ok, _} = Runs.set_pinned(run, false)
    assert Retention.run(days_later(365)) == %{artifacts: 1, logs: 1}
  end

  test "keeps the latest failure per test definition and environment", context do
    older_failure = finished_run(context, :failed)
    latest_failure = finished_run(context, :timeout)
    later_pass = finished_run(context, :passed)

    other_environment = environment_fixture(project: context.project)
    other_failure = finished_run(%{context | environment: other_environment}, :error)

    assert Retention.run(days_later(365)) == %{artifacts: 2, logs: 2}

    refute artifacts?(older_failure)
    refute artifacts?(later_pass)
    assert artifacts?(latest_failure) and logs?(latest_failure)
    assert artifacts?(other_failure) and logs?(other_failure)

    # A newer failure takes over the exception.
    newest_failure = finished_run(context, :error)
    assert Retention.run(days_later(365)) == %{artifacts: 1, logs: 1}
    refute artifacts?(latest_failure)
    assert artifacts?(newest_failure)
  end

  test "ignores active runs and runs without artifacts or logs", context do
    active =
      run_fixture(
        test_definition: context.test_definition,
        environment: context.environment,
        status: :running
      )

    {:ok, empty} =
      Runs.finish(
        run_fixture(
          test_definition: context.test_definition,
          environment: context.environment,
          status: :running
        ).id,
        %Result{status: :passed, finished_at: @finished_at}
      )

    assert Retention.run(days_later(365)) == %{artifacts: 0, logs: 0}
    assert %{artifacts_expired_at: nil, logs_expired_at: nil} = Runs.get_run!(active.id)
    assert %{artifacts_expired_at: nil, logs_expired_at: nil} = Runs.get_run!(empty.id)
  end

  test "handles at most 100 runs per call", context do
    for _ <- 1..101, do: finished_run(context)

    assert Retention.run(days_later(365)) == %{artifacts: 100, logs: 100}
    assert Retention.run(days_later(365)) == %{artifacts: 1, logs: 1}
  end

  test "the worker runs retention" do
    assert :ok = perform_job(CleanupWorker, %{})
  end
end
