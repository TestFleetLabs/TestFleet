defmodule TestFleet.Execution.Integration.ArtifactsTest do
  # Spike step 5: copy the artifacts directory out of the stopped container.
  use TestFleet.DockerCase, async: true

  @moduletag :tmp_dir

  test "copies nested artifacts with their contents", %{tmp_dir: tmp_dir} do
    {request, _pid} = start_run!(environment: %{"SPIKE_MODE" => "pass"}, artifact_path: tmp_dir)
    {result, _} = await_finished(request.run_id)

    assert [%{path: "reports/index.html"}, %{path: "summary.txt", size_bytes: size}] =
             result.artifacts

    assert File.read!(Path.join(tmp_dir, "summary.txt")) == "run #{request.run_id}\n"
    assert File.read!(Path.join(tmp_dir, "reports/index.html")) =~ "report"
    assert size == byte_size("run #{request.run_id}\n")

    # No leftovers from the download and extraction.
    assert tmp_dir |> File.ls!() |> Enum.sort() == ["reports", "summary.txt"]
  end

  test "an empty artifacts directory means no artifacts", %{tmp_dir: tmp_dir} do
    {result, _} = run!(environment: %{"SPIKE_MODE" => "no_artifacts"}, artifact_path: tmp_dir)

    assert result.status == :passed
    assert result.artifacts == []
  end

  test "a missing artifacts directory is not an error", %{tmp_dir: tmp_dir} do
    {result, _} =
      run!(image: "alpine:3", pull_policy: :if_missing, command: ["true"], artifact_path: tmp_dir)

    assert result.status == :passed
    assert result.artifacts == []
  end
end
