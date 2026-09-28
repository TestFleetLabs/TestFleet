defmodule TestFleetWeb.ArtifactControllerTest do
  # Milestone 6 section 7: downloads, their headers, and range requests.
  use TestFleetWeb.ConnCase, async: true

  import TestFleet.RunsFixtures

  alias TestFleet.Artifacts.Storage
  alias TestFleet.Execution.Result
  alias TestFleet.Runs

  @sandbox "sandbox allow-scripts allow-popups allow-forms"

  @files %{
    "reports/index.html" => "<html><script>alert(1)</script></html>",
    "screenshots/login page.png" => "not really a png",
    "trace.zip" => "PK",
    "report.pdf" => "%PDF-1.7",
    "video.webm" => "0123456789"
  }

  setup do
    run = run_fixture(status: :running)

    for {name, content} <- @files do
      path = Path.join(Storage.run_dir(run.id), name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    # Present on disk, but not a stored artifact: must never be served.
    File.write!(Path.join(Storage.run_dir(run.id), "unlisted.txt"), "secret")

    artifacts = for {name, content} <- @files, do: %{path: name, size_bytes: byte_size(content)}

    {:ok, run} =
      Runs.finish(run.id, %Result{
        run_id: run.id,
        status: :passed,
        exit_code: 0,
        finished_at: DateTime.utc_now(),
        artifacts: artifacts
      })

    %{run: run}
  end

  defp artifact_path(run, path), do: "/runs/#{run.id}/artifacts/#{path}"

  test "serves HTML inline in a sandbox", %{conn: conn, run: run} do
    conn = get(conn, artifact_path(run, "reports/index.html"))

    assert response(conn, 200) == @files["reports/index.html"]
    assert get_resp_header(conn, "content-type") == ["text/html"]
    assert get_resp_header(conn, "content-security-policy") == [@sandbox]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert ["inline; " <> _] = get_resp_header(conn, "content-disposition")
  end

  test "serves images inline, with an encoded name", %{conn: conn, run: run} do
    conn = get(conn, artifact_path(run, "screenshots/login%20page.png"))

    assert response(conn, 200) == "not really a png"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "content-security-policy") == [@sandbox]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(inline; filename="login page.png"; filename*=UTF-8''login%20page.png)
           ]
  end

  test "serves PDFs inline without the sandbox", %{conn: conn, run: run} do
    conn = get(conn, artifact_path(run, "report.pdf"))

    assert response(conn, 200) == "%PDF-1.7"
    # Phoenix's default policy, without the sandbox.
    refute Enum.any?(get_resp_header(conn, "content-security-policy"), &(&1 =~ "sandbox"))
    assert ["inline; " <> _] = get_resp_header(conn, "content-disposition")
  end

  test "other types are downloaded", %{conn: conn, run: run} do
    conn = get(conn, artifact_path(run, "trace.zip"))

    assert response(conn, 200) == "PK"
    assert get_resp_header(conn, "content-type") == ["application/zip"]
    assert ["attachment; " <> _] = get_resp_header(conn, "content-disposition")
  end

  test "unknown names are not found, even when the file exists", %{conn: conn, run: run} do
    assert conn |> get(artifact_path(run, "unlisted.txt")) |> response(404)
    assert conn |> get(artifact_path(run, "missing.png")) |> response(404)
    assert conn |> get("/runs/not-a-number/artifacts/trace.zip") |> response(404)
  end

  test "names with .. are not found", %{conn: conn, run: run} do
    assert conn |> get(artifact_path(run, "reports/../trace.zip")) |> response(404)
    assert conn |> get(artifact_path(run, "..%2F..%2Fsecret")) |> response(404)
  end

  test "another run's artifact is not found", %{conn: conn, run: run} do
    other = run_fixture()
    assert conn |> get(artifact_path(other, "trace.zip")) |> response(404)
    assert conn |> get(artifact_path(run, "trace.zip")) |> response(200)
  end

  test "a stored artifact whose file is gone is not found", %{conn: conn, run: run} do
    File.rm!(Path.join(Storage.run_dir(run.id), "trace.zip"))
    assert conn |> get(artifact_path(run, "trace.zip")) |> response(404)
  end

  describe "range requests" do
    defp get_range(conn, run, range),
      do: conn |> put_req_header("range", range) |> get(artifact_path(run, "video.webm"))

    test "a closed range", %{conn: conn, run: run} do
      conn = get_range(conn, run, "bytes=2-5")

      assert response(conn, 206) == "2345"
      assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    end

    test "an open range, and a suffix", %{conn: conn, run: run} do
      assert conn |> get_range(run, "bytes=7-") |> response(206) == "789"
      assert conn |> get_range(run, "bytes=-3") |> response(206) == "789"
      assert conn |> get_range(run, "bytes=8-100") |> response(206) == "89"
    end

    test "an unsatisfiable range", %{conn: conn, run: run} do
      conn = get_range(conn, run, "bytes=10-")

      assert response(conn, 416)
      assert get_resp_header(conn, "content-range") == ["bytes */10"]
    end

    test "several ranges or a malformed header serve the whole file", %{conn: conn, run: run} do
      assert conn |> get_range(run, "bytes=0-1,4-5") |> response(200) == "0123456789"
      assert conn |> get_range(run, "items=0-1") |> response(200) == "0123456789"
    end
  end
end
