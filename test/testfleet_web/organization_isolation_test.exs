defmodule TestFleetWeb.OrganizationIsolationTest do
  # Another organization's records are "not found" in pages, downloads, and the API.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.AccountsFixtures
  import TestFleet.EnvironmentsFixtures
  import TestFleet.OrganizationsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Artifacts

  setup %{conn: conn} do
    other = organization_fixture()
    project = project_fixture(slug: "theirs", organization: other)

    run =
      run_fixture(
        project: project,
        test_definition: test_definition_fixture(project: project, slug: "e2e"),
        environment: environment_fixture(project: project, slug: "staging")
      )

    Artifacts.insert_all(run, [%{path: "report.html", size_bytes: 3}])

    %{conn: conn, run: run}
  end

  describe "pages and downloads" do
    setup :register_and_log_in_user

    test "a run of another organization is not found", %{conn: conn, run: run} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/runs/#{run.id}") end
      assert_error_sent 404, fn -> get(conn, ~p"/runs/#{run.id}/log") end
      assert conn |> get(~p"/runs/#{run.id}/artifacts/report.html") |> response(404)
    end

    test "a project of another organization is not found", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/projects/theirs") end
    end

    test "its runs are not listed, and do not arrive live", %{conn: conn, run: run} do
      ours = run_fixture()
      {:ok, lv, _html} = live(conn, ~p"/runs")
      assert has_element?(lv, "#runs-#{ours.id}")
      refute has_element?(lv, "#runs-#{run.id}")

      later = run_fixture(project: run.test_definition.project)
      ours_later = run_fixture(project: ours.test_definition.project)
      assert has_element?(lv, "#runs-#{ours_later.id}")
      refute has_element?(lv, "#runs-#{later.id}")
    end
  end

  describe "the API" do
    setup %{conn: conn} do
      {token, _api_token} = api_token_fixture(user_fixture())
      %{conn: put_req_header(conn, "authorization", "Bearer " <> token)}
    end

    test "answers 404 for another organization's runs and projects", %{conn: conn, run: run} do
      for path <- [
            ~p"/api/v1/runs/#{run.id}",
            ~p"/api/v1/runs/#{run.id}/log",
            ~p"/api/v1/runs/#{run.id}/artifacts",
            ~p"/api/v1/runs/#{run.id}/artifacts/report.html",
            ~p"/api/v1/projects/theirs/test-definitions/e2e"
          ] do
        assert conn |> get(path) |> response(404), path
      end

      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          ~p"/api/v1/projects/theirs/runs",
          Jason.encode!(%{test_definition: "e2e", environment: "staging"})
        )

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end
end
