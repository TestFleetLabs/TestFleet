defmodule TestFleetWeb.API.RunFileControllerTest do
  # A run's log and artifacts over the API
  use TestFleetWeb.ConnCase, async: true

  import TestFleet.AccountsFixtures
  import TestFleet.RunsFixtures

  alias TestFleet.Artifacts.Storage
  alias TestFleet.Execution.Result
  alias TestFleet.Repo
  alias TestFleet.Runs

  @sandbox "sandbox allow-scripts allow-popups allow-forms"

  setup %{conn: conn} do
    {token, _api_token} = api_token_fixture(user_fixture())
    %{conn: put_req_header(conn, "authorization", "Bearer " <> token), token: token}
  end

  # A fresh conn with the token: recycle/1 drops request headers.
  defp authed(%{token: token}),
    do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  defp line(sequence, content),
    do: %{sequence: sequence, stream: :stdout, content: content, timestamp: sequence}

  defp append(run, lines, opts \\ []), do: :ok = Runs.append_log(run.id, lines, opts)

  describe "GET /api/v1/runs/:id/log" do
    test "streams the whole log as text with the last sequence", %{conn: conn} do
      run = run_fixture(status: :running)
      append(run, for(n <- 1..1_500, do: line(n, "line #{n}")))

      conn = get(conn, ~p"/api/v1/runs/#{run}/log")

      assert response(conn, 200) == Enum.map_join(1..1_500, &"line #{&1}\n")
      assert response_content_type(conn, :text)
      assert get_resp_header(conn, "testfleet-log-sequence") == ["1500"]
      assert get_resp_header(conn, "content-disposition") == []
    end

    test "sends only the lines after a sequence", context do
      run = run_fixture(status: :running)
      append(run, [line(1, "one"), line(2, "two")])

      conn = context |> authed() |> get(~p"/api/v1/runs/#{run}/log?after=1")
      assert response(conn, 200) == "two\n"
      assert get_resp_header(conn, "testfleet-log-sequence") == ["2"]

      # Nothing new: an empty body, and the same sequence to ask from next time.
      conn = context |> authed() |> get(~p"/api/v1/runs/#{run}/log?after=2")
      assert response(conn, 200) == ""
      assert get_resp_header(conn, "testfleet-log-sequence") == ["2"]

      append(run, [line(3, "three")])
      conn = context |> authed() |> get(~p"/api/v1/runs/#{run}/log?after=2")
      assert response(conn, 200) == "three\n"
    end

    test "an empty log answers sequence 0", %{conn: conn} do
      run = run_fixture()
      conn = get(conn, ~p"/api/v1/runs/#{run}/log")

      assert response(conn, 200) == ""
      assert get_resp_header(conn, "testfleet-log-sequence") == ["0"]
    end

    test "ends a truncated log with the note, but not an incremental one", context do
      run = run_fixture(status: :running)
      append(run, [line(1, "kept"), line(2, "dropped")], max_log_bytes: 4)

      body = context |> authed() |> get(~p"/api/v1/runs/#{run}/log") |> response(200)
      assert ["kept", note, ""] = String.split(body, "\n")
      assert note =~ "Log limit"

      assert context |> authed() |> get(~p"/api/v1/runs/#{run}/log?after=0") |> response(200) ==
               "kept\n"

      assert %{"log_truncated" => true} =
               context |> authed() |> get(~p"/api/v1/runs/#{run}") |> json_response(200)
    end

    test "refuses an invalid sequence", %{conn: conn} do
      run = run_fixture()

      assert %{"error" => %{"details" => %{"after" => _}}} =
               conn |> get(~p"/api/v1/runs/#{run}/log?after=-1") |> json_response(422)
    end

    test "is 410 after retention and 404 for an unknown run", context do
      run = run_fixture(status: :passed, logs_expired_at: ~U[2026-09-01 00:00:00.000000Z])

      assert %{"error" => %{"code" => "expired", "message" => message}} =
               context |> authed() |> get(~p"/api/v1/runs/#{run}/log") |> json_response(410)

      assert message =~ "2026-09-01"
      assert context |> authed() |> get(~p"/api/v1/runs/0/log") |> json_response(404)
    end
  end

  describe "artifacts" do
    @files %{
      "report/index.html" => "<html><script>alert(1)</script></html>",
      "screenshots/login page.png" => "not really a png",
      "video.webm" => "0123456789"
    }

    setup do
      run = run_fixture(status: :running)

      for {name, content} <- @files do
        path = Path.join(Storage.run_dir(run.id), name)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end

      {:ok, run} =
        Runs.finish(run.id, %Result{
          run_id: run.id,
          status: :passed,
          exit_code: 0,
          finished_at: DateTime.utc_now(),
          artifacts:
            for({name, content} <- @files, do: %{path: name, size_bytes: byte_size(content)})
        })

      %{run: run}
    end

    test "lists them with their download URLs", %{conn: conn, run: run} do
      assert %{"artifacts" => artifacts} =
               conn |> get(~p"/api/v1/runs/#{run}/artifacts") |> json_response(200)

      assert [
               %{
                 "name" => "report/index.html",
                 "content_type" => "text/html",
                 "size_bytes" => 38
               },
               %{"name" => "screenshots/login page.png", "url" => png_url},
               %{"name" => "video.webm"}
             ] = artifacts

      assert png_url =~ "/api/v1/runs/#{run.id}/artifacts/screenshots/login%20page.png"
    end

    test "the run links to them", %{conn: conn, run: run} do
      assert %{"artifacts_url" => url, "log_url" => log_url} =
               conn |> get(~p"/api/v1/runs/#{run}") |> json_response(200)

      assert url =~ "/api/v1/runs/#{run.id}/artifacts"
      assert log_url =~ "/api/v1/runs/#{run.id}/log"
    end

    test "sends a file as an attachment, in a sandbox", %{conn: conn, run: run} do
      conn = get(conn, ~p"/api/v1/runs/#{run}/artifacts/report/index.html")

      assert response(conn, 200) == @files["report/index.html"]
      assert get_resp_header(conn, "content-type") == ["text/html"]
      assert get_resp_header(conn, "content-security-policy") == [@sandbox]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert [~s(attachment; filename="index.html") <> _] =
               get_resp_header(conn, "content-disposition")
    end

    test "supports ranges", %{conn: conn, run: run} do
      conn =
        conn
        |> put_req_header("range", "bytes=2-5")
        |> get(~p"/api/v1/runs/#{run}/artifacts/video.webm")

      assert response(conn, 206) == "2345"
    end

    test "never serves a file that is not a stored artifact", context do
      %{run: run} = context
      File.write!(Path.join(Storage.run_dir(run.id), "unlisted.txt"), "secret")

      for path <- [
            ~p"/api/v1/runs/#{run}/artifacts/unlisted.txt",
            "/api/v1/runs/#{run.id}/artifacts/../#{run.id}/unlisted.txt"
          ] do
        assert %{"error" => %{"code" => "not_found"}} =
                 context |> authed() |> get(path) |> json_response(404)
      end
    end

    test "is 404 when the file is missing", %{conn: conn, run: run} do
      File.rm!(Path.join(Storage.run_dir(run.id), "video.webm"))
      assert conn |> get(~p"/api/v1/runs/#{run}/artifacts/video.webm") |> json_response(404)
    end

    test "are 410 after retention", context do
      run =
        context.run
        |> Ecto.Changeset.change(artifacts_expired_at: ~U[2026-09-01 00:00:00.000000Z])
        |> Repo.update!()

      for path <- [
            ~p"/api/v1/runs/#{run}/artifacts",
            ~p"/api/v1/runs/#{run}/artifacts/video.webm"
          ] do
        assert %{"error" => %{"code" => "expired"}} =
                 context |> authed() |> get(path) |> json_response(410)
      end
    end
  end
end
