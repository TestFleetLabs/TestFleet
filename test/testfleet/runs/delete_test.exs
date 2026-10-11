defmodule TestFleet.Runs.DeleteTest do
  # Deleting a run removes its artifact files and everything stored with it.
  use TestFleet.DataCase, async: true

  import TestFleet.RunsFixtures

  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.Storage
  alias TestFleet.Execution.Result
  alias TestFleet.Notifications.EvaluateWorker
  alias TestFleet.Results
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  # A finished run with an artifact (on disk and as a row), a test result, and a log.
  defp finished_run do
    run = run_fixture(status: :running)

    file = Path.join(Storage.run_dir(run.id), "screenshots/login.png")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "png")

    :ok =
      Runs.append_log(run.id, [
        %{sequence: 1, stream: :stdout, content: "one", timestamp: 1},
        %{sequence: 2, stream: :stderr, content: "two", timestamp: 2}
      ])

    {:ok, run} =
      Runs.finish(run.id, %Result{
        run_id: run.id,
        status: :failed,
        exit_code: 1,
        finished_at: DateTime.utc_now(),
        artifacts: [%{path: "screenshots/login.png", size_bytes: 3}],
        test_results: [
          %{
            suite: "login",
            classname: "LoginTest",
            name: "signs in",
            status: :failed,
            duration_ms: 120,
            failure_message: "expected 200",
            failure_details: nil,
            file: "junit.xml"
          }
        ]
      })

    run
  end

  test "deletes a finished run with its artifacts, log, and test results, then broadcasts" do
    run = finished_run()
    Runs.subscribe(run.id)

    assert {:ok, %Run{id: id}} = Runs.delete_run(run)
    assert id == run.id
    assert_receive {:run_deleted, %Run{id: ^id}}

    assert Runs.get_run(run.id) == nil
    refute File.exists?(Storage.run_dir(run.id))
    assert Artifacts.list_artifacts(run) == []
    assert Results.list_test_results(run) == []
    assert Runs.list_log_tail(run, 10) == []
  end

  test "a run deleted meanwhile is not found" do
    run = finished_run()

    assert {:ok, _run} = Runs.delete_run(run)
    assert Runs.delete_run(run) == {:error, :not_found}
  end

  test "queued and active runs are not deleted" do
    for status <- [:queued, :preparing, :running] do
      run = run_fixture(status: status)

      assert Runs.delete_run(run) == {:error, :not_final}
      assert %Run{status: ^status} = Runs.get_run(run.id)
    end
  end

  test "the notification evaluation of a deleted run is cancelled" do
    run = finished_run()
    {:ok, _run} = Runs.delete_run(run)

    assert {:cancel, _reason} = perform_job(EvaluateWorker, %{run_id: run.id})
  end
end
