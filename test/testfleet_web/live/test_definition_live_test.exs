defmodule TestFleetWeb.TestDefinitionLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.ProjectsFixtures
  import TestFleet.RegistriesFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.TestDefinitions

  setup do
    %{project: project_fixture(%{name: "Customer Portal"})}
  end

  describe "project page" do
    test "shows an empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")
      assert has_element?(view, "#test-definitions-empty-state")
    end

    test "lists test definitions linking to their page", %{conn: conn, project: project} do
      test_definition =
        test_definition_fixture(project: project, name: "Checkout", timeout_seconds: 2700)

      disabled = test_definition_fixture(project: project, name: "Legacy", enabled: false)

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      row = "#test_definitions-#{test_definition.id}"
      assert has_element?(view, row, "Checkout")
      assert has_element?(view, row, "registry.company.com/customer-a/e2e:1.17")
      assert has_element?(view, row, "45 min")

      assert has_element?(
               view,
               "#{row} a[href='/projects/customer-portal/test-definitions/#{test_definition.id}']"
             )

      assert has_element?(view, "#test_definitions-#{disabled.id}", "disabled")
      refute has_element?(view, row, "disabled")
    end
  end

  describe "form" do
    test "creates a test definition and returns to the project", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")

      {:ok, show, _html} =
        view
        |> form("#test-definition-form",
          test_definition: %{
            name: "Customer Portal E2E",
            image: "registry.company.com/customer-a/e2e:1.17",
            command_text: "./run-e2e.sh\n--workers\n4",
            timeout_minutes: "45",
            cpu_limit: "2",
            memory_limit_mib: "4096"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert [test_definition] = TestDefinitions.list_test_definitions(project)

      assert %{
               slug: "customer-portal-e2e",
               command: ["./run-e2e.sh", "--workers", "4"],
               timeout_seconds: 2700,
               cpu_limit: 2.0,
               memory_limit: 4_294_967_296,
               shm_size_bytes: 2_147_483_648
             } = test_definition

      assert has_element?(show, "#test_definitions-#{test_definition.id}")
    end

    test "the new form starts with the defaults", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")

      assert has_element?(view, "#test_definition_timeout_minutes[value='30']")
      assert has_element?(view, "#test_definition_shm_size_mib[value='2048']")
      assert has_element?(view, "#test_definition_enabled[checked]")
    end

    test "shows validation errors next to the inputs", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")

      view
      |> form("#test-definition-form",
        test_definition: %{name: "Suite", image: "e2e:", timeout_minutes: "0"}
      )
      |> render_submit()

      assert has_element?(view, "#test_definition_image.border-error")
      assert has_element?(view, "#test_definition_timeout_minutes.border-error")
      assert TestDefinitions.list_test_definitions(project) == []
    end

    test "edits a test definition and returns to its page", %{conn: conn, project: project} do
      test_definition = test_definition_fixture(project: project, command: ["./run.sh"])
      path = ~p"/projects/customer-portal/test-definitions/#{test_definition.id}"

      {:ok, view, _html} = live(conn, "#{path}/edit")

      assert has_element?(view, "#test_definition_command_text", "./run.sh")

      {:ok, _show, _html} =
        view
        |> form("#test-definition-form",
          test_definition: %{image: "alpine:3", command_text: "", enabled: "false"}
        )
        |> render_submit()
        |> follow_redirect(conn, path)

      assert %{image: "alpine:3", command: [], enabled: false, timeout_seconds: 1800} =
               TestDefinitions.get_test_definition!(project, test_definition.id)
    end

    test "deletes a test definition", %{conn: conn, project: project} do
      test_definition = test_definition_fixture(project: project)

      {:ok, view, _html} =
        live(conn, ~p"/projects/customer-portal/test-definitions/#{test_definition.id}/edit")

      {:ok, _show, _html} =
        view
        |> element("#delete-test-definition")
        |> render_click()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert TestDefinitions.list_test_definitions(project) == []
    end

    test "a test definition of another project is not found", %{conn: conn} do
      other = test_definition_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/projects/customer-portal/test-definitions/#{other.id}/edit")
      end
    end
  end

  describe "image source" do
    test "names the registry whose credentials a pull uses", %{conn: conn} do
      registry = registry_fixture(name: "Company GitLab", host: "registry.company.com")
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")

      view
      |> form("#test-definition-form",
        test_definition: %{image: "registry.company.com/customer-a/e2e:1.17"}
      )
      |> render_change()

      assert has_element?(view, "#image-source", "Company GitLab")
      assert has_element?(view, "#image-source a[href='/registries/#{registry.id}/edit']")
    end

    test "says when an image is pulled anonymously", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")

      view
      |> form("#test-definition-form",
        test_definition: %{image: "mcr.microsoft.com/playwright:v1"}
      )
      |> render_change()

      assert has_element?(view, "#image-source", "mcr.microsoft.com")
      assert has_element?(view, "#image-source a[href='/registries/new']")
    end

    test "says nothing for an empty or invalid image", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/test-definitions/new")
      refute has_element?(view, "#image-source")

      view |> form("#test-definition-form", test_definition: %{image: "e2e:"}) |> render_change()
      refute has_element?(view, "#image-source")
    end
  end
end
