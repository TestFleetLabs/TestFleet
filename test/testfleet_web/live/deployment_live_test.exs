defmodule TestFleetWeb.DeploymentLiveTest do
  # What a pipeline deployed, as runs show it: the run page, its Changes panel,
  # and the runs list (spec sections 7 and 41).
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs.Deployment

  @commit "9fceb02d0ae598e95dc970b74767f19372d61af8"
  # The comparison queries can take longer than render_async's default 100 ms
  # while the whole suite runs.
  @async_timeout 2_000

  setup :register_and_log_in_user

  setup do
    project = project_fixture()

    %{
      test_definition: test_definition_fixture(project: project),
      environment: environment_fixture(project: project)
    }
  end

  defp run(context, deployment) do
    finished_run_fixture(
      test_definition: context.test_definition,
      environment: context.environment,
      trigger: :api,
      deployment: deployment,
      tests: [{"pays", :passed}]
    )
  end

  test "the run page names the deployment and links to it", %{conn: conn} = context do
    run =
      run(context, %Deployment{
        version: "1.4.2",
        commit: @commit,
        url: "https://ci.example.com/acme/portal/pipelines/12"
      })

    {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")

    assert has_element?(view, "#run-deployment-version", "1.4.2")
    assert has_element?(view, "#run-deployment-commit[title='#{@commit}']", "9fceb02")

    assert has_element?(
             view,
             "#run-deployment-link[href='https://ci.example.com/acme/portal/pipelines/12'][rel='noopener noreferrer']",
             "ci.example.com"
           )
  end

  test "a run without a deployment shows none", %{conn: conn} = context do
    run = run(context, nil)
    {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")

    refute has_element?(view, "#run-deployment")
  end

  test "the Changes panel says whether the deployment changed", %{conn: conn} = context do
    run(context, %Deployment{version: "1.4.1"})
    same = run(context, %Deployment{version: "1.4.1"})
    changed = run(context, %Deployment{version: "1.4.2", commit: @commit})
    without = run(context, nil)

    changes = fn run ->
      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{run.id}")
      render_async(view, @async_timeout)
      view
    end

    assert has_element?(changes.(same), "#run-changes-deployment[data-changed='false']", "1.4.1")

    assert has_element?(
             changes.(changed),
             "#run-changes-deployment[data-changed='true']",
             "1.4.1 → 1.4.2 (9fceb02)"
           )

    assert has_element?(changes.(without), "#run-changes-deployment[data-changed='true']", "→ –")
  end

  test "the runs list names the version", %{conn: conn} = context do
    run(context, %Deployment{version: "1.4.2"})
    {:ok, view, _html} = live(conn, ~p"/#{org()}/runs")

    assert has_element?(view, "#run-list [data-deployment]", "1.4.2")
  end
end
