defmodule TestFleet.Runs.FinishTest do
  # The final status, counts, artifacts, and test results in
  # one transaction.
  use TestFleet.DataCase, async: true

  import TestFleet.RunsFixtures

  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.Artifact
  alias TestFleet.Execution.Result
  alias TestFleet.Results
  alias TestFleet.Results.TestResult
  alias TestFleet.Runs
  alias TestFleet.Runs.Run

  setup do
    %{run: run_fixture(status: :running)}
  end

  defp result(run, fields) do
    struct!(
      %Result{run_id: run.id, status: :failed, exit_code: 1, finished_at: DateTime.utc_now()},
      fields
    )
  end

  defp test_case(name, status, fields \\ []) do
    Enum.into(fields, %{
      suite: "login",
      classname: "LoginTest",
      name: name,
      status: status,
      duration_ms: 120,
      failure_message: nil,
      failure_details: nil,
      file: "junit.xml"
    })
  end

  test "stores counts, warnings, artifacts, and test results, then broadcasts", %{run: run} do
    Runs.subscribe(run.id)

    result =
      result(run,
        artifacts: [
          %{path: "junit.xml", size_bytes: 812},
          %{path: "screenshots/login.png", size_bytes: 20_480}
        ],
        test_results: [
          test_case("signs in", :passed),
          test_case("rejects a wrong password", :failed,
            failure_message: "expected 401",
            failure_details: "at login.spec.ts:12"
          ),
          test_case("remembers the user", :skipped),
          test_case("logs out", :error, failure_message: "browser crashed")
        ],
        warnings: ["1 entry was skipped: links or unsafe paths"]
      )

    assert {:ok, %Run{status: :failed}} = Runs.finish(run.id, result)

    assert_receive {:run_finished,
                    %Run{tests_passed: 1, tests_failed: 2, tests_skipped: 1} = finished}

    assert finished.warnings == ["1 entry was skipped: links or unsafe paths"]

    assert [
             %Artifact{
               name: "junit.xml",
               content_type: "text/xml",
               size_bytes: 812,
               storage_backend: "local",
               storage_key: junit_key
             },
             %Artifact{name: "screenshots/login.png", content_type: "image/png"}
           ] = Artifacts.list_artifacts(finished)

    assert junit_key == "#{run.id}/junit.xml"

    assert [
             %TestResult{
               name: "rejects a wrong password",
               status: :failed,
               failure_message: "expected 401",
               failure_details: "at login.spec.ts:12",
               test_definition_id: test_definition_id,
               file: "junit.xml"
             },
             %TestResult{name: "logs out", status: :error},
             %TestResult{name: "signs in", status: :passed, duration_ms: 120},
             %TestResult{name: "remembers the user", status: :skipped}
           ] = Results.list_test_results(finished)

    assert test_definition_id == run.test_definition_id
  end

  test "a run without JUnit has no counts", %{run: run} do
    assert {:ok, finished} =
             Runs.finish(run.id, result(run, artifacts: [%{path: "log.txt", size_bytes: 3}]))

    assert %{tests_passed: nil, tests_failed: nil, tests_skipped: nil, warnings: []} = finished
    assert [%Artifact{name: "log.txt"}] = Artifacts.list_artifacts(finished)
    assert Results.list_test_results(finished) == []
  end

  test "a repeated finish changes and inserts nothing", %{run: run} do
    first =
      result(run,
        artifacts: [%{path: "junit.xml", size_bytes: 812}],
        test_results: [test_case("signs in", :passed)]
      )

    assert {:ok, finished} = Runs.finish(run.id, first)

    second =
      result(run,
        status: :passed,
        artifacts: [%{path: "junit.xml", size_bytes: 1}, %{path: "late.txt", size_bytes: 1}],
        test_results: [test_case("signs in", :passed), test_case("again", :passed)]
      )

    assert Runs.finish(run.id, second) == :error

    assert %{status: :failed, tests_passed: 1} = Runs.get_run!(run.id)
    assert [%Artifact{name: "junit.xml", size_bytes: 812}] = Artifacts.list_artifacts(finished)
    assert [%TestResult{name: "signs in"}] = Results.list_test_results(finished)
  end

  test "a failing insert leaves the run unfinished", %{run: run} do
    Runs.subscribe(run.id)
    broken = result(run, test_results: [test_case(nil, :passed)])

    assert_raise Postgrex.Error, fn -> Runs.finish(run.id, broken) end

    assert %{status: :running, tests_passed: nil} = Runs.get_run!(run.id)
    refute_received {:run_finished, _}
  end

  test "stores thousands of test results", %{run: run} do
    cases = for i <- 1..2_500, do: test_case("test #{i}", :passed)

    assert {:ok, %{tests_passed: 2_500}} = Runs.finish(run.id, result(run, test_results: cases))
    assert Repo.aggregate(from(t in TestResult, where: t.run_id == ^run.id), :count) == 2_500
  end
end
