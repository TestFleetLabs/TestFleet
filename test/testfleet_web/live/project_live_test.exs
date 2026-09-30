defmodule TestFleetWeb.ProjectLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.ProjectsFixtures

  alias TestFleet.Projects

  setup :register_and_log_in_user

  describe "index" do
    test "lists projects linking to their pages", %{conn: conn} do
      project = project_fixture(%{name: "Customer Portal"})
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert has_element?(view, "#projects-#{project.id}[href='/projects/customer-portal']")
      assert has_element?(view, "#projects-empty")
    end

    test "links to the new project form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects")

      assert {:ok, _form, _html} =
               view
               |> element("#new-project")
               |> render_click()
               |> follow_redirect(conn, ~p"/projects/new")
    end
  end

  describe "new" do
    test "creates a project and opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      {:ok, show, _html} =
        view
        |> form("#project-form", project: %{name: "Customer Portal", slug: ""})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/customer-portal")

      assert has_element?(show, "#project")
      assert Projects.get_project_by_slug!("customer-portal").name == "Customer Portal"
    end

    # Fields left out of form/3 are taken from the rendered DOM, like a browser does.
    test "generates the slug from the whole name while typing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      for name <- ["A", "Austria", "Austria Codex Online"] do
        view |> form("#project-form", project: %{name: name}) |> render_change()
      end

      refute has_element?(view, "#project_slug[value]:not([value=''])")
      assert has_element?(view, "#project_slug[placeholder='austria-codex-online']")

      {:ok, _show, _html} =
        view
        |> form("#project-form", project: %{name: "Austria Codex Online"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/austria-codex-online")
    end

    test "keeps a slug typed by hand", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      view
      |> form("#project-form", project: %{name: "Austria Codex Online", slug: "aco"})
      |> render_change()

      assert has_element?(view, "#project_slug[value='aco']")

      {:ok, _show, _html} =
        view
        |> form("#project-form", project: %{name: "Austria Codex Online, renamed"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/aco")
    end

    test "shows validation errors and saves nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/new")

      view
      |> form("#project-form", project: %{name: "", slug: "Bad Slug"})
      |> render_change()

      assert has_element?(view, "#project-form #project_slug.border-error")
      assert has_element?(view, "#project-form #project_name.border-error")

      view |> form("#project-form", project: %{name: "", slug: "Bad Slug"}) |> render_submit()

      assert has_element?(view, "#project-form")
      assert Projects.list_projects() == []
    end
  end

  describe "edit" do
    test "saves changes and follows a changed slug", %{conn: conn} do
      project_fixture(%{name: "Customer Portal"})
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal/edit")

      {:ok, _show, _html} =
        view
        |> form("#project-form", project: %{name: "Portal", slug: "portal"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/projects/portal")

      assert Projects.get_project_by_slug!("portal").name == "Portal"
    end
  end

  describe "show" do
    test "shows the project with its sections", %{conn: conn} do
      project_fixture(%{name: "Customer Portal"})
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      assert page_title(view) == "Customer Portal · TestFleet"
      assert has_element?(view, "#test-definitions")
      assert has_element?(view, "#environments")
      assert has_element?(view, "#schedules")
      assert has_element?(view, "#nav-projects[aria-current=page]")
    end

    test "deletes the project", %{conn: conn} do
      project = project_fixture(%{name: "Customer Portal"})
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      {:ok, index, _html} =
        view
        |> element("#delete-project")
        |> render_click()
        |> follow_redirect(conn, ~p"/projects")

      refute has_element?(index, "#projects-#{project.id}")
      assert Projects.list_projects() == []
    end

    test "an unknown slug is a 404", %{conn: conn} do
      assert_error_sent 404, fn -> get(conn, ~p"/projects/missing") end
    end
  end
end
