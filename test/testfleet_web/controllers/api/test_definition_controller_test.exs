defmodule TestFleetWeb.API.TestDefinitionControllerTest do
  # Reading a test definition and updating its image
  use TestFleetWeb.ConnCase, async: true

  import TestFleet.AccountsFixtures
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs

  @path "/api/v1/projects/portal/test-definitions/e2e"

  setup %{conn: conn} do
    {token, _api_token} = api_token_fixture(user_fixture())
    project = project_fixture(slug: "portal")

    test_definition =
      test_definition_fixture(
        project: project,
        name: "E2E",
        slug: "e2e",
        image: "ghcr.io/acme/e2e:1.4"
      )

    %{
      conn: put_req_header(conn, "authorization", "Bearer " <> token),
      token: token,
      project: project,
      test_definition: test_definition
    }
  end

  defp patch_json(conn, body, path \\ @path) do
    conn
    |> put_req_header("content-type", "application/json")
    |> patch(path, Jason.encode!(body))
  end

  # Every request gets a fresh conn with the token: recycle/1 drops request headers.
  defp authed(%{token: token}),
    do: put_req_header(build_conn(), "authorization", "Bearer " <> token)

  describe "GET" do
    test "returns the test definition", %{conn: conn} do
      assert %{
               "slug" => "e2e",
               "name" => "E2E",
               "project" => "portal",
               "image" => "ghcr.io/acme/e2e:1.4",
               "enabled" => true,
               "updated_at" => _
             } = conn |> get(@path) |> json_response(200)
    end

    test "names what is unknown", context do
      assert %{"error" => %{"message" => ~s(No project "nope".)}} =
               context
               |> authed()
               |> get(~p"/api/v1/projects/nope/test-definitions/e2e")
               |> json_response(404)

      assert %{"error" => %{"message" => ~s(No test definition "x" in project "portal".)}} =
               context
               |> authed()
               |> get(~p"/api/v1/projects/portal/test-definitions/x")
               |> json_response(404)
    end

    test "requires a token" do
      assert build_conn() |> get(@path) |> json_response(401)
    end
  end

  describe "PATCH" do
    test "replaces the tag", %{conn: conn} do
      assert %{"image" => "ghcr.io/acme/e2e:1.5"} =
               conn |> patch_json(%{"tag" => "1.5"}) |> json_response(200)
    end

    test "replaces the whole image", %{conn: conn} do
      assert %{"image" => "registry.example.com:5000/e2e@sha256:" <> _} =
               conn
               |> patch_json(%{
                 "image" => "registry.example.com:5000/e2e@sha256:#{String.duplicate("a", 64)}"
               })
               |> json_response(200)
    end

    test "applies to the next run, not to a queued one", context do
      environment = environment_fixture(project: context.project)
      queued = run_fixture(test_definition: context.test_definition, environment: environment)

      context.conn |> patch_json(%{"tag" => "1.5"}) |> json_response(200)

      assert Runs.get_run!(queued.id).image == "ghcr.io/acme/e2e:1.4"
      {:ok, next} = Runs.create_run(context.test_definition, environment)
      assert next.image == "ghcr.io/acme/e2e:1.5"
    end

    test "refuses invalid images and tags", context do
      assert %{"error" => %{"code" => "invalid", "details" => %{"tag" => ["is not a valid tag"]}}} =
               context |> authed() |> patch_json(%{"tag" => "1:5"}) |> json_response(422)

      assert %{"error" => %{"details" => %{"image" => ["is not a valid image reference"]}}} =
               context |> authed() |> patch_json(%{"image" => "e2e:"}) |> json_response(422)

      assert %{"error" => %{"details" => %{"image" => ["can't be blank"]}}} =
               context |> authed() |> patch_json(%{"image" => ""}) |> json_response(422)

      assert TestFleet.Repo.reload!(context.test_definition).image == "ghcr.io/acme/e2e:1.4"
    end

    test "takes exactly one of image and tag, and nothing else", context do
      for {body, field} <- [
            {%{"image" => "e2e:2", "tag" => "2"}, "tag"},
            {%{}, "image"},
            {%{"tag" => "2", "enabled" => "false"}, "enabled"},
            {%{"tag" => 2}, "tag"}
          ] do
        assert %{"error" => %{"code" => "invalid", "details" => details}} =
                 context |> authed() |> patch_json(body) |> json_response(422)

        assert Map.has_key?(details, field), inspect(body)
      end

      assert TestFleet.Repo.reload!(context.test_definition).image == "ghcr.io/acme/e2e:1.4"
    end

    test "names an unknown test definition", %{conn: conn} do
      assert conn
             |> patch_json(%{"tag" => "2"}, ~p"/api/v1/projects/portal/test-definitions/x")
             |> json_response(404)
    end
  end
end
