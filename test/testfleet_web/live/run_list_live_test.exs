defmodule TestFleetWeb.RunListLiveTest do
  # The runs list: filters and pages in the URL, and live updates that respect them.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs
  alias TestFleet.Runs.Deployment

  setup :register_and_log_in_user

  setup do
    project = project_fixture(name: "Portal", slug: "portal")
    test_definition = test_definition_fixture(project: project)

    %{
      project: project,
      test_definition: test_definition,
      production: environment_fixture(project: project, slug: "production"),
      staging: environment_fixture(project: project, slug: "staging")
    }
  end

  defp run(context, attrs \\ []) do
    run_fixture(
      Keyword.merge(
        [test_definition: context.test_definition, environment: context.production],
        attrs
      )
    )
  end

  defp runs_path(query \\ []), do: ~p"/#{org()}/runs?#{query}"

  test "filters from the URL", %{conn: conn} = context do
    failed = run(context, status: :failed)
    passed = run(context, status: :passed)
    staging = run(context, environment: context.staging, status: :failed)

    {:ok, view, _html} =
      live(conn, runs_path(project: "portal", environment: "production", status: "failed"))

    assert has_element?(view, "#runs-#{failed.id}")
    refute has_element?(view, "#runs-#{passed.id}")
    refute has_element?(view, "#runs-#{staging.id}")

    assert has_element?(
             view,
             "#run-filters select[name='status'] option[selected][value='failed']"
           )

    assert has_element?(view, "#run-filters-clear")
  end

  test "changing a filter puts it in the URL", %{conn: conn} = context do
    run(context, deployment: %Deployment{version: "1.4.2"})
    {:ok, view, _html} = live(conn, runs_path())

    # An environment needs a project.
    assert has_element?(view, "#run-filters select[name='environment'][disabled]")

    view
    |> form("#run-filters", %{
      "project" => "portal",
      "trigger" => "api",
      "deployment" => " 1.4.2 "
    })
    |> render_change()

    assert_patch(view, runs_path(deployment: "1.4.2", project: "portal", trigger: "api"))
    refute has_element?(view, "#run-filters select[name='environment'][disabled]")
    assert has_element?(view, "#runs-empty-filtered")
  end

  test "leaves out values it does not know", %{conn: conn} = context do
    shown = run(context)

    {:ok, view, _html} =
      live(conn, runs_path(project: "nope", status: "bogus", from: "yesterday", before: "x"))

    assert has_element?(view, "#runs-#{shown.id}")
    refute has_element?(view, "#run-filters-active")
  end

  test "filters by day in the default timezone", %{conn: conn} = context do
    inside = run(context, queued_at: ~U[2026-11-03 12:00:00.000000Z])
    outside = run(context, queued_at: ~U[2026-11-05 12:00:00.000000Z])

    {:ok, view, _html} = live(conn, runs_path(from: "2026-11-03", to: "2026-11-04"))

    assert has_element?(view, "#runs-#{inside.id}")
    refute has_element?(view, "#runs-#{outside.id}")
  end

  test "pages through older and newer runs", %{conn: conn} = context do
    runs = for _ <- 1..52, do: run(context, status: :passed)
    [oldest, second_oldest | _] = runs
    newest = List.last(runs)

    {:ok, view, _html} = live(conn, runs_path(status: "passed"))
    assert has_element?(view, "#runs-#{newest.id}")
    refute has_element?(view, "#runs-#{second_oldest.id}")
    refute has_element?(view, "#runs-newer")

    view |> element("#runs-older") |> render_click()
    third_oldest = Enum.at(runs, 2)
    assert_patch(view, runs_path(before: third_oldest.id, status: "passed"))
    assert has_element?(view, "#runs-#{oldest.id}")
    assert has_element?(view, "#runs-#{second_oldest.id}")
    refute has_element?(view, "#runs-#{newest.id}")
    refute has_element?(view, "#runs-older")

    view |> element("#runs-newer") |> render_click()
    assert_patch(view, runs_path(after: second_oldest.id, status: "passed"))
    assert has_element?(view, "#runs-#{newest.id}")
    assert has_element?(view, "#runs-#{third_oldest.id}")
    refute has_element?(view, "#runs-newer")
    assert has_element?(view, "#runs-older")
  end

  test "new runs appear live only when they pass the filters", %{conn: conn} = context do
    {:ok, view, _html} = live(conn, runs_path(environment: "staging", project: "portal"))

    {:ok, production} = Runs.create_run(context.test_definition, context.production)
    {:ok, staging} = Runs.create_run(context.test_definition, context.staging)

    assert has_element?(view, "#runs-#{staging.id}")
    refute has_element?(view, "#runs-#{production.id}")
  end

  test "older pages do not receive new runs", %{conn: conn} = context do
    first = run(context)
    second = run(context)

    {:ok, view, _html} = live(conn, runs_path(before: second.id))
    assert has_element?(view, "#runs-#{first.id}")

    {:ok, new} = Runs.create_run(context.test_definition, context.production)
    refute has_element?(view, "#runs-#{new.id}")
  end
end
