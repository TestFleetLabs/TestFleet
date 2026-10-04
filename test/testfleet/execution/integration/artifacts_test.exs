defmodule TestFleet.Execution.Integration.ArtifactsTest do
  # Collect the artifacts directory and the JUnit results out of the stopped container.
  use TestFleet.DockerCase, async: true

  @moduletag :tmp_dir
  # Collection warnings are logged by RunExecution.
  @moduletag :capture_log

  defp run_mode!(tmp_dir, mode, attrs \\ []) do
    {result, _lines} =
      run!(
        [
          environment: Map.merge(%{"FIXTURE_MODE" => mode}, attrs[:env] || %{}),
          artifact_path: tmp_dir
        ] ++
          Keyword.delete(attrs, :env)
      )

    result
  end

  defp names(result), do: Enum.map(result.artifacts, & &1.path)

  test "copies nested artifacts with their contents", %{tmp_dir: tmp_dir} do
    {request, _pid} = start_run!(environment: %{"FIXTURE_MODE" => "pass"}, artifact_path: tmp_dir)
    {result, _} = await_finished(request.run_id)

    assert [%{path: "reports/index.html"}, %{path: "summary.txt", size_bytes: size}] =
             result.artifacts

    assert File.read!(Path.join(tmp_dir, "summary.txt")) == "run #{request.run_id}\n"
    assert File.read!(Path.join(tmp_dir, "reports/index.html")) =~ "report"
    assert size == byte_size("run #{request.run_id}\n")

    # No leftovers from the download and extraction.
    assert tmp_dir |> File.ls!() |> Enum.sort() == ["reports", "summary.txt"]
    refute File.exists?(tmp_dir <> ".tar")
    refute File.exists?(tmp_dir <> ".extract")
  end

  test "an empty artifacts directory means no artifacts", %{tmp_dir: tmp_dir} do
    result = run_mode!(tmp_dir, "no_artifacts")

    assert result.status == :passed
    assert result.artifacts == []
    assert result.test_results == nil
    assert result.warnings == []
  end

  test "a missing artifacts directory is not an error", %{tmp_dir: tmp_dir} do
    {result, _} =
      run!(image: "alpine:3", pull_policy: :if_missing, command: ["true"], artifact_path: tmp_dir)

    assert result.status == :passed
    assert result.artifacts == []
  end

  describe "JUnit" do
    test "results are parsed, and failures fail the run", %{tmp_dir: tmp_dir} do
      result = run_mode!(tmp_dir, "junit_fail")

      assert result.status == :failed
      assert names(result) == ["junit.xml", "screenshots/checkout.png"]

      assert [
               %{name: "adds", status: :passed, duration_ms: 1000, file: "junit.xml"},
               %{name: "pays", status: :failed, failure_message: "expected 200, got 500"},
               %{name: "crashes", status: :error}
             ] = result.test_results
    end

    test "passing results with a skip", %{tmp_dir: tmp_dir} do
      result = run_mode!(tmp_dir, "junit_pass")

      assert result.status == :passed
      assert [%{status: :passed}, %{status: :skipped}] = result.test_results
    end

    test "rule 6: exit code 0 with failures is failed", %{tmp_dir: tmp_dir} do
      result = run_mode!(tmp_dir, "junit_swallow")

      assert result.exit_code == 0
      assert result.status == :failed
    end

    test "rule 9: a crash without failing tests is an error", %{tmp_dir: tmp_dir} do
      result = run_mode!(tmp_dir, "junit_crash")

      assert result.status == :error
      assert result.error_message =~ "exited with code 1, but its JUnit report has no failures"
    end

    test "shards are merged, and an unreadable file is a warning", %{tmp_dir: tmp_dir} do
      result = run_mode!(tmp_dir, "junit_shards")

      assert result.status == :failed

      assert [
               %{name: "one", file: "junit/shard-1.xml"},
               %{name: "two", file: "junit/shard-2.xml"}
             ] =
               result.test_results

      assert [warning] = result.warnings
      assert warning =~ "junit/broken.xml could not be parsed"
    end
  end

  describe "size limit" do
    test "over the limit, only the JUnit files are kept", %{tmp_dir: tmp_dir} do
      result =
        run_mode!(tmp_dir, "big_artifacts",
          env: %{"FIXTURE_ARTIFACT_MB" => "3"},
          max_artifact_bytes: 1024 * 1024
        )

      assert result.status == :passed
      assert names(result) == ["junit.xml"]
      assert [%{name: "records a video"}] = result.test_results
      assert result.warnings == ["Artifacts exceeded 1 MiB; only the JUnit files were kept"]
      refute File.exists?(tmp_dir <> ".tar")
    end

    test "under the limit, everything is kept", %{tmp_dir: tmp_dir} do
      result =
        run_mode!(tmp_dir, "big_artifacts",
          env: %{"FIXTURE_ARTIFACT_MB" => "1"},
          max_artifact_bytes: 2 * 1024 * 1024
        )

      assert names(result) == ["junit.xml", "video.webm"]
      assert result.warnings == []
    end
  end

  test "links in the archive are skipped", %{tmp_dir: tmp_dir} do
    result = run_mode!(tmp_dir, "unsafe_artifacts")

    assert names(result) == ["report.txt"]
    assert result.warnings == ["1 entry was skipped: links or unsafe paths"]
    refute File.exists?(Path.join(tmp_dir, "passwd"))
  end

  test "a cancelled run keeps what it wrote", %{tmp_dir: tmp_dir} do
    {request, _pid} = start_run!(environment: %{"FIXTURE_MODE" => "hang"}, artifact_path: tmp_dir)
    await_output(request.run_id, &(&1.content == "tick 1"))

    :ok = Execution.cancel(request.run_id)
    {result, _} = await_finished(request.run_id)

    assert result.status == :cancelled
    assert "summary.txt" in names(result)
  end
end
