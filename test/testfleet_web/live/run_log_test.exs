defmodule TestFleetWeb.RunLogTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.RunsFixtures

  alias TestFleet.Runs
  alias TestFleetWeb.RunComponents

  defp line(sequence, content, stream \\ :stdout),
    do: %{sequence: sequence, stream: stream, content: content, timestamp: sequence}

  defp append(run, lines, opts \\ []), do: :ok = Runs.append_log(run.id, lines, opts)

  defp content_text(view, sequence) do
    view
    |> element("#log-#{sequence} > span:last-child")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
  end

  describe "log panel" do
    test "shows the stored lines of a finished run", %{conn: conn} do
      run = run_fixture(status: :passed, finished_at: DateTime.utc_now())
      append(run, [line(1, "starting suite"), line(2, "a warning", :stderr)])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#log-1", "starting suite")
      assert has_element?(view, "#log-2[data-stream='stderr']", "a warning")
      assert has_element?(view, "#run-output-count", "2 lines")
      assert has_element?(view, "#download-log[href='/runs/#{run.id}/log']")
      refute has_element?(view, "#run-output-earlier")
    end

    test "appends output live, without repeating lines it already shows", %{conn: conn} do
      run = run_fixture(status: :running)
      append(run, [line(1, "tick 1")])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(view, "#run-output-live")

      # An overlapping batch, as after subscribing before loading the history.
      append(run, [line(1, "tick 1"), line(2, "tick 2")])

      assert has_element?(view, "#log-2", "tick 2")
      # The empty-state placeholder, then exactly two lines.
      assert has_element?(view, "#log-lines > li:nth-child(3)#log-2")
      refute has_element?(view, "#log-lines > li:nth-child(4)")
    end

    test "shows masked values as a badge", %{conn: conn} do
      run = run_fixture(status: :running)
      append(run, [line(1, "token=[MASKED] used")])

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#log-1 span span", "MASKED")
      refute has_element?(view, "#log-1", "[MASKED]")

      # The content is shown with pre-wrap, so any extra whitespace would be visible.
      assert content_text(view, 1) == "token=MASKED used"
    end

    test "points to the download when earlier lines are not shown", %{conn: conn} do
      run = run_fixture(status: :passed, finished_at: DateTime.utc_now())
      append(run, for(n <- 1..1_005, do: line(n, "line #{n}")))

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      refute has_element?(view, "#log-5")
      assert has_element?(view, "#log-6")
      assert has_element?(view, "#run-output-earlier a[href='/runs/#{run.id}/log']")
    end

    test "shows what to expect without output", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/runs/#{run_fixture(status: :running).id}")
      assert has_element?(view, "#log-empty", "Waiting for output")

      finished = run_fixture(status: :passed, finished_at: DateTime.utc_now())
      {:ok, view, _html} = live(conn, ~p"/runs/#{finished.id}")
      assert has_element?(view, "#log-empty", "no output")
      refute has_element?(view, "#download-log")
    end

    test "says when the log limit was reached, live", %{conn: conn} do
      run = run_fixture(status: :running)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      refute has_element?(view, "#run-output-truncated")

      append(run, [line(1, "12345"), line(2, "678")], max_log_bytes: 6)

      assert has_element?(view, "#run-output-truncated")
      # Shown while watching, though not stored.
      assert has_element?(view, "#log-2", "678")
    end
  end

  describe "download" do
    test "returns the stored log as a text file", %{conn: conn} do
      run = run_fixture(status: :passed, finished_at: DateTime.utc_now())
      append(run, for(n <- 1..2_500, do: line(n, "line #{n}")))

      conn = get(conn, ~p"/runs/#{run.id}/log")

      assert response_content_type(conn, :text) =~ "charset=utf-8"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="run-#{run.id}.log")
             ]

      assert response(conn, 200) == Enum.map_join(1..2_500, &"line #{&1}\n")
    end

    test "ends a truncated log with a note", %{conn: conn} do
      run = run_fixture(status: :passed, finished_at: DateTime.utc_now())
      append(run, [line(1, "kept"), line(2, "dropped")], max_log_bytes: 4)

      body = conn |> get(~p"/runs/#{run.id}/log") |> response(200)

      assert ["kept", note, ""] = String.split(body, "\n")
      assert note =~ "Log limit"
    end

    test "an unknown run is not found", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/runs/0/log") end
    end
  end

  describe "log_segments/1" do
    test "strips ANSI escape sequences" do
      assert RunComponents.log_segments("\e[32m✓\e[0m passed \e]0;title\a") == ["✓ passed "]
    end

    test "separates masked values" do
      assert RunComponents.log_segments("[MASKED]:[MASKED] x") == [:masked, ":", :masked, " x"]
    end
  end
end
