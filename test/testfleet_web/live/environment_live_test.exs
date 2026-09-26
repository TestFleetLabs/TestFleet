defmodule TestFleetWeb.EnvironmentLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures

  alias TestFleet.Environments
  alias TestFleet.Environments.Variable

  setup do
    project = project_fixture(%{name: "Customer Portal"})
    %{project: project}
  end

  describe "project page" do
    test "lists the environments with their variable counts", %{conn: conn, project: project} do
      environment = environment_fixture(project: project, name: "Production")
      variable_fixture(environment)

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      assert has_element?(
               view,
               "#environments-#{environment.id} a[href='/projects/customer-portal/environments/production']"
             )

      assert has_element?(view, "#environments-#{environment.id}", "1 variable")
    end
  end

  describe "form" do
    test "creates an environment and opens it", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/new")

      {:ok, show, _html} =
        view
        |> form("#environment-form",
          environment: %{name: "Production", slug: "", max_concurrent_runs: "2"}
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal/environments/production")

      assert has_element?(show, "#environment")
      assert Environments.get_environment!(project, "production").max_concurrent_runs == 2
    end

    # Fields left out of form/3 are taken from the rendered DOM, like a browser does.
    test "generates the slug from the whole name while typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/new")

      for name <- ["P", "Pre", "Pre-Production"] do
        view |> form("#environment-form", environment: %{name: name}) |> render_change()
      end

      assert has_element?(view, "#environment_slug[placeholder='pre-production']")

      {:ok, _show, _html} =
        view
        |> form("#environment-form", environment: %{name: "Pre-Production"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal/environments/pre-production")
    end

    test "edits an environment", %{conn: conn, project: project} do
      environment_fixture(project: project, name: "Production")
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production/edit")

      {:ok, _show, _html} =
        view
        |> form("#environment-form", environment: %{name: "Prod", slug: "prod"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal/environments/prod")
    end
  end

  describe "variables" do
    setup %{project: project} do
      %{environment: environment_fixture(project: project, name: "Production")}
    end

    test "adds a variable", %{conn: conn, project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production")
      assert has_element?(view, "#variables-empty")

      view
      |> form("#variable-form", variable: %{key: "BASE_URL", value: "https://shop.example"})
      |> render_submit()

      [variable] = Environments.get_environment!(project, "production").variables
      assert variable.value == "https://shop.example"
      assert has_element?(view, "#variables-#{variable.id}", "https://shop.example")
      refute has_element?(view, "#variables-empty")
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production")

      view
      |> form("#variable-form", variable: %{key: "TestFleet_RUN_ID", value: "x"})
      |> render_submit()

      assert has_element?(view, "#variable-form #variable_key.border-error")
    end

    # Security: these checks are about what reaches the browser, so they look at the HTML.
    test "a secret value never reaches the browser", %{conn: conn, environment: environment} do
      variable =
        variable_fixture(environment, %{key: "API_TOKEN", value: "s3cret-value", secret: true})

      {:ok, view, html} = live(conn, ~p"/projects/customer-portal/environments/production")
      refute html =~ "s3cret-value"

      view |> element("#edit-variable-#{variable.id}") |> render_click()
      refute render(view) =~ "s3cret-value"
      assert has_element?(view, "#variable-form #variable_value[type=password]")

      # A failed save must not echo the stored value either.
      view
      |> form("#variable-form", variable: %{key: "bad key", value: "", secret: "true"})
      |> render_submit()

      refute render(view) =~ "s3cret-value"
    end

    test "editing a secret with an empty value keeps it", %{conn: conn, environment: environment} do
      variable =
        variable_fixture(environment, %{key: "API_TOKEN", value: "s3cret-value", secret: true})

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production")

      view |> element("#edit-variable-#{variable.id}") |> render_click()
      assert has_element?(view, "#variable-form-editing", "API_TOKEN")

      view
      |> form("#variable-form", variable: %{key: "TOKEN", value: "", secret: "true"})
      |> render_submit()

      stored = TestFleet.Repo.get!(Variable, variable.id)
      assert {stored.key, stored.value} == {"TOKEN", "s3cret-value"}
      refute has_element?(view, "#variable-form-editing")
    end

    test "deletes a variable", %{conn: conn, environment: environment} do
      variable = variable_fixture(environment, %{key: "BASE_URL"})
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production")

      view |> element("#delete-variable-#{variable.id}") |> render_click()

      refute has_element?(view, "#variables-#{variable.id}")
      assert has_element?(view, "#variables-empty")
      refute TestFleet.Repo.get(Variable, variable.id)
    end
  end

  test "deletes an environment", %{conn: conn, project: project} do
    environment_fixture(project: project, name: "Production")
    {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/environments/production")

    {:ok, _project_view, _html} =
      view
      |> element("#delete-environment")
      |> render_click()
      |> follow_redirect(conn, ~p"/projects/customer-portal")

    assert Environments.list_environments(project) == []
  end
end
