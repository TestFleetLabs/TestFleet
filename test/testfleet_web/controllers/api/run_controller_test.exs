defmodule TestFleetWeb.API.RunControllerTest do
  # Runs over the API (Milestone 11, sections 4 to 6)
  use TestFleetWeb.ConnCase, async: true

  import TestFleet.AccountsFixtures
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.{Runs, TestDefinitions}
  alias TestFleet.Runs.Run

  setup %{conn: conn} do
    user = user_fixture()
    {token, api_token} = api_token_fixture(user, %{name: "deploy"})
    project = project_fixture(slug: "portal")

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      user: user,
      api_token: api_token,
      project: project,
      test_definition: test_definition_fixture(project: project, slug: "e2e", image: "e2e:1.4"),
      environment: environment_fixture(project: project, slug: "staging")
    }
  end

  defp post_json(conn, path, body) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(body))
  end

  defp start(conn, body \\ %{"test_definition" => "e2e", "environment" => "staging"}),
    do: post_json(conn, ~p"/api/v1/projects/portal/runs", body)

  describe "authentication" do
    test "refuses requests without a valid token", %{user: user} do
      for header <- [nil, "Bearer nope", "Basic dXNlcjpwYXNz", "Bearer"] do
        conn = build_conn()
        conn = if header, do: put_req_header(conn, "authorization", header), else: conn
        conn = get(conn, ~p"/api/v1/runs/1")

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(conn, 401)
        assert get_resp_header(conn, "www-authenticate") == [~s(Bearer realm="TestFleet")]
      end

      # A browser session is not enough.
      conn = build_conn() |> log_in_user(user) |> get(~p"/api/v1/runs/1")
      assert json_response(conn, 401)
    end

    test "accepts the scheme in any case", %{conn: conn} do
      ["Bearer " <> token] = get_req_header(conn, "authorization")

      conn =
        build_conn()
        |> put_req_header("authorization", "bearer " <> token)
        |> start()

      assert json_response(conn, 201)
    end
  end

  describe "POST /api/v1/projects/:project/runs" do
    test "starts a queued API run", %{conn: conn, user: user, api_token: api_token} do
      Runs.subscribe()
      conn = start(conn)

      assert %{"id" => id} = body = json_response(conn, 201)
      assert get_resp_header(conn, "location") == ["/api/v1/runs/#{id}"]

      assert %{
               "project" => "portal",
               "test_definition" => "e2e",
               "environment" => "staging",
               "trigger" => "api",
               "triggered_by" => email,
               "status" => "queued",
               "final" => false,
               "image" => "e2e:1.4",
               "tests" => nil
             } = body

      assert email == user.email
      assert body["url"] =~ "/runs/#{id}"

      run = Runs.get_run!(id)
      assert %Run{trigger: :api, triggered_by_user_id: user_id, api_token_id: token_id} = run
      assert {user_id, token_id} == {user.id, api_token.id}
      assert_receive {:run_created, %Run{id: ^id}}
    end

    test "names what is unknown", %{conn: conn} do
      for {path, body, message} <- [
            {~p"/api/v1/projects/nope/runs",
             %{"test_definition" => "e2e", "environment" => "staging"}, ~s(No project "nope".)},
            {~p"/api/v1/projects/portal/runs",
             %{"test_definition" => "x", "environment" => "staging"},
             ~s(No test definition "x" in project "portal".)},
            {~p"/api/v1/projects/portal/runs",
             %{"test_definition" => "e2e", "environment" => "x"},
             ~s(No environment "x" in project "portal".)}
          ] do
        conn = conn |> recycle_auth() |> post_json(path, body)

        assert %{"error" => %{"code" => "not_found", "message" => ^message}} =
                 json_response(conn, 404)
      end
    end

    test "does not find an environment of another project", %{conn: conn} do
      environment_fixture(slug: "elsewhere")

      conn = start(conn, %{"test_definition" => "e2e", "environment" => "elsewhere"})
      assert json_response(conn, 404)
    end

    test "refuses a disabled test definition", %{conn: conn, test_definition: test_definition} do
      {:ok, _} = TestDefinitions.update_test_definition(test_definition, %{enabled: false})

      conn = start(conn)
      assert %{"error" => %{"code" => "test_definition_disabled"}} = json_response(conn, 409)
    end

    test "refuses unknown, missing, and non-string fields", %{conn: conn} do
      conn = start(conn, %{"test_definition" => 1, "enviroment" => "staging"})

      assert %{
               "error" => %{
                 "code" => "invalid",
                 "details" => %{
                   "test_definition" => ["must be a string"],
                   "enviroment" => ["is not a known field"],
                   "environment" => ["can't be blank"]
                 }
               }
             } = json_response(conn, 422)
    end

    test "refuses a body that is not a JSON object", %{conn: conn} do
      conn = start(conn, ["e2e"])
      assert %{"error" => %{"code" => "bad_request"}} = json_response(conn, 400)

      conn =
        conn
        |> recycle_auth()
        |> put_req_header("content-type", "application/x-www-form-urlencoded")
        |> post(~p"/api/v1/projects/portal/runs", "test_definition=e2e&environment=staging")

      assert %{"error" => %{"message" => "Send the body as JSON" <> _}} = json_response(conn, 400)
    end

    test "refuses malformed JSON", %{conn: conn} do
      {400, _headers, body} =
        assert_error_sent 400, fn ->
          conn
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "*/*")
          |> post(~p"/api/v1/projects/portal/runs", "{")
        end

      assert %{"error" => %{"code" => "bad_request"}} = Jason.decode!(body)
    end
  end

  describe "GET /api/v1/runs/:id" do
    test "returns the run with its result", %{conn: conn, test_definition: test_definition} do
      run =
        run_fixture(
          test_definition: test_definition,
          status: :failed,
          exit_code: 1,
          tests_passed: 41,
          tests_failed: 2,
          tests_skipped: 3
        )

      conn = get(conn, ~p"/api/v1/runs/#{run}")

      assert %{
               "id" => id,
               "status" => "failed",
               "final" => true,
               "trigger" => "manual",
               "triggered_by" => nil,
               "exit_code" => 1,
               "tests" => %{"passed" => 41, "failed" => 2, "skipped" => 3}
             } = json_response(conn, 200)

      assert id == run.id
    end

    test "is 404 for an unknown or malformed id", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/v1/runs/0"), 404)
      assert json_response(conn |> recycle_auth() |> get(~p"/api/v1/runs/abc"), 404)
    end
  end

  describe "POST /api/v1/runs/:id/cancel" do
    test "cancels a queued run", %{conn: conn, test_definition: test_definition} do
      run = run_fixture(test_definition: test_definition)

      conn = post(conn, ~p"/api/v1/runs/#{run}/cancel")
      assert %{"status" => "cancelled", "final" => true} = json_response(conn, 202)
    end

    test "leaves a finished run as it is", %{conn: conn, test_definition: test_definition} do
      run = run_fixture(test_definition: test_definition, status: :passed)

      conn = post(conn, ~p"/api/v1/runs/#{run}/cancel")
      assert %{"status" => "passed"} = json_response(conn, 202)
    end
  end

  # recycle/1 keeps cookies, not request headers.
  defp recycle_auth(conn) do
    [authorization] = get_req_header(conn, "authorization")
    build_conn() |> put_req_header("authorization", authorization)
  end
end
