defmodule TestFleetWeb.RunResultsLiveTest do
  # Milestone 6 section 7: the tests and artifacts panels, and counts in run lists.
  use TestFleetWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import TestFleet.RunsFixtures

  alias TestFleet.Execution.Result
  alias TestFleet.Runs

  defp finish(run, fields) do
    result =
      struct!(
        %Result{run_id: run.id, status: :failed, exit_code: 1, finished_at: DateTime.utc_now()},
        fields
      )

    {:ok, run} = Runs.finish(run.id, result)
    run
  end

  defp test_case(name, status, fields \\ []) do
    Enum.into(fields, %{
      suite: "checkout",
      classname: "Cart",
      name: name,
      status: status,
      duration_ms: 1_500,
      failure_message: nil,
      failure_details: nil,
      file: "junit.xml"
    })
  end

  defp junit_run(passed \\ 3) do
    run = run_fixture(status: :running)

    finish(run,
      test_results:
        [
          test_case("pays", :failed,
            failure_message: "expected 200, got 500",
            failure_details: "at pay (cart.spec.ts:12)"
          ),
          test_case("crashes", :error, failure_message: "TypeError")
        ] ++
          for(i <- 1..passed, do: test_case("adds #{i}", :passed)) ++
          [test_case("later", :skipped)]
    )
  end

  describe "tests panel" do
    test "shows the counts and the failures, with their details", %{conn: conn} do
      run = junit_run()
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-tests-summary", "3 passed")
      assert has_element?(view, "#run-tests-summary", "2 failed")
      assert has_element?(view, "#run-tests-summary", "1 skipped")
      assert has_element?(view, "#run-tests-duration", "9.0s")

      assert has_element?(view, "#test-failures li[data-status='failed']", "pays")

      assert has_element?(
               view,
               "#test-failures li[data-status='failed']",
               "expected 200, got 500"
             )

      assert has_element?(
               view,
               "#test-failures li[data-status='failed'] details pre",
               "cart.spec.ts:12"
             )

      assert has_element?(view, "#test-failures li[data-status='error']", "crashes")
      refute has_element?(view, "#test-failures li[data-status='passed']")

      # Shown pre-wrapped, so the text must be exactly the message.
      [message] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#test-failures li[data-status='failed'] [data-failure-message]")
        |> Enum.map(&LazyHTML.text/1)

      assert message == "expected 200, got 500"
      refute has_element?(view, "#test-others")
    end

    test "shows all tests on demand", %{conn: conn} do
      run = junit_run()
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#show-all-tests", "Show all 6 tests")
      view |> element("#show-all-tests") |> render_click()

      assert has_element?(view, "#test-others li[data-status='passed']", "adds 3")
      assert has_element?(view, "#test-others li[data-status='skipped']", "later")
      refute has_element?(view, "#show-all-tests")
    end

    test "a passing run says that nothing failed", %{conn: conn} do
      run =
        finish(run_fixture(status: :running),
          status: :passed,
          test_results: [test_case("adds", :passed)]
        )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#test-failures-empty")
      assert has_element?(view, "#show-all-tests")
    end

    test "is not shown without JUnit", %{conn: conn} do
      run = finish(run_fixture(status: :running), [])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#run-tests")
    end

    test "appears when the run finishes while the page is open", %{conn: conn} do
      run = run_fixture(status: :running)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#run-tests")

      finish(run,
        test_results: [test_case("pays", :failed)],
        artifacts: [%{path: "junit.xml", size_bytes: 812}]
      )

      assert has_element?(view, "#test-failures li[data-status='failed']", "pays")
      assert has_element?(view, "#artifact-tree li[data-kind='file']", "junit.xml")
    end
  end

  describe "artifacts panel" do
    setup do
      run =
        finish(run_fixture(status: :running),
          artifacts: [
            %{path: "junit.xml", size_bytes: 812},
            %{path: "reports/assets/app.js", size_bytes: 2_048},
            %{path: "reports/index.html", size_bytes: 4_096},
            %{path: "screenshots/login page.png", size_bytes: 20_480},
            %{path: "trace.html", size_bytes: 100},
            %{path: "videos/checkout.webm", size_bytes: 3 * 1024 * 1024}
          ],
          warnings: ["1 entry was skipped: links or unsafe paths"]
        )

      %{run: run}
    end

    test "lists the files as a tree, directories first", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-artifacts-summary", "6 files")
      assert has_element?(view, "#run-artifacts-summary", "3.0 MiB")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#artifact-tree > li")
        |> Enum.map(&{LazyHTML.attribute(&1, "data-kind"), LazyHTML.text(&1)})
        |> Enum.map(fn {[kind], text} -> {kind, text |> String.split() |> hd()} end)

      assert rows == [
               {"dir", "reports/"},
               {"dir", "assets/"},
               {"file", "app.js"},
               {"file", "index.html"},
               {"dir", "screenshots/"},
               {"file", "login"},
               {"dir", "videos/"},
               {"file", "checkout.webm"},
               {"file", "junit.xml"},
               {"file", "trace.html"}
             ]
    end

    test "links to the files, keeping the directories in the URL", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(
               view,
               "#artifact-tree a[href='/runs/#{run.id}/artifacts/screenshots/login%20page.png']"
             )

      # A directory with an index.html, and a standalone HTML file, open as reports.
      assert has_element?(
               view,
               "#artifact-tree li[data-kind='dir'] a[data-report][href='/runs/#{run.id}/artifacts/reports/index.html']"
             )

      assert has_element?(
               view,
               "#artifact-tree a[data-report][href='/runs/#{run.id}/artifacts/trace.html']"
             )
    end

    test "previews images and videos", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(
               view,
               "#artifact-media img[src='/runs/#{run.id}/artifacts/screenshots/login%20page.png']"
             )

      assert has_element?(
               view,
               "#artifact-media video[src='/runs/#{run.id}/artifacts/videos/checkout.webm']"
             )
    end

    test "shows the warnings", %{conn: conn, run: run} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-warnings", "1 entry was skipped")
    end
  end

  test "a run without artifacts or warnings has no artifacts panel", %{conn: conn} do
    run = finish(run_fixture(status: :running), [])
    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    refute has_element?(view, "#run-artifacts")
  end

  test "warnings are shown without artifacts", %{conn: conn} do
    run =
      finish(run_fixture(status: :running), warnings: ["Artifacts could not be collected: boom"])

    {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

    assert has_element?(view, "#run-warnings", "boom")
    refute has_element?(view, "#artifact-tree li")
  end

  describe "retention" do
    test "the pin toggle pins and unpins a finished run", %{conn: conn} do
      run = finish(run_fixture(status: :running), [])
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#pin-run[aria-pressed='false']")
      view |> element("#pin-run") |> render_click()
      assert has_element?(view, "#pin-run[aria-pressed='true']")
      assert Runs.get_run!(run.id).pinned

      view |> element("#pin-run") |> render_click()
      refute Runs.get_run!(run.id).pinned
    end

    test "an active run has no pin toggle", %{conn: conn} do
      run = run_fixture(status: :running)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#pin-run")
    end

    test "expired artifacts and logs are shown as expired; tests stay", %{conn: conn} do
      run = junit_run()

      TestFleet.Repo.update_all(
        from(r in TestFleet.Runs.Run, where: r.id == ^run.id),
        set: [
          artifacts_expired_at: ~U[2026-09-01 10:00:00.000000Z],
          logs_expired_at: ~U[2026-09-01 10:00:00.000000Z],
          last_log_sequence: 42
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-artifacts-expired", "1 Sep 2026")
      assert has_element?(view, "#log-empty", "The log expired on 1 Sep 2026")
      refute has_element?(view, "#download-log")
      assert has_element?(view, "#test-failures li[data-status='failed']", "pays")
    end

    test "expiry while the page is open clears artifacts and log", %{conn: conn} do
      run = run_fixture(status: :running)
      file = Path.join(TestFleet.Artifacts.Storage.run_dir(run.id), "shot.png")
      File.mkdir_p!(Path.dirname(file))
      File.write!(file, "png")

      :ok =
        Runs.append_log(run.id, [%{sequence: 1, stream: :stdout, content: "hello", timestamp: 1}])

      # Passed: the latest failure would be kept.
      finish(run,
        status: :passed,
        exit_code: 0,
        finished_at: ~U[2026-01-01 00:00:00.000000Z],
        artifacts: [%{path: "shot.png", size_bytes: 3}]
      )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#artifact-tree li", "shot.png")
      assert has_element?(view, "#log-lines li[data-stream]", "hello")

      TestFleet.Retention.run(~U[2027-01-01 00:00:00Z])

      assert has_element?(view, "#run-artifacts-expired")
      refute has_element?(view, "#artifact-tree li")
      refute has_element?(view, "#artifact-media")
      refute has_element?(view, "#log-lines li[data-stream]")
      assert has_element?(view, "#log-empty", "The log expired")
    end

    test "downloading an expired log says so", %{conn: conn} do
      run = finish(run_fixture(status: :running), [])

      TestFleet.Repo.update_all(
        from(r in TestFleet.Runs.Run, where: r.id == ^run.id),
        set: [logs_expired_at: ~U[2026-09-01 10:00:00.000000Z]]
      )

      assert conn |> get(~p"/runs/#{run.id}/log") |> response(410) =~ "expired on 2026-09-01"
    end
  end

  test "run lists show the test counts", %{conn: conn} do
    run = junit_run()
    {:ok, view, _html} = live(conn, ~p"/runs")

    assert has_element?(view, "#runs-#{run.id}-tests [data-count='passed']", "3")
    assert has_element?(view, "#runs-#{run.id}-tests [data-count='failed']", "2")
    assert has_element?(view, "#runs-#{run.id}-tests [data-count='skipped']", "1")
  end
end
