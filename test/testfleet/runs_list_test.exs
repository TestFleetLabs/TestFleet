defmodule TestFleet.RunsListTest do
  # The runs list's filters and pages, and whether a new run belongs in a list.
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs
  alias TestFleet.Runs.Deployment

  setup do
    project = project_fixture()
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

  defp ids(opts), do: org_scope() |> Runs.list_runs(opts) |> Enum.map(& &1.id)

  test "filters by environment, status, and trigger", context do
    failed = run(context, status: :failed)
    staging = run(context, environment: context.staging, status: :failed)
    api = run(context, status: :passed, trigger: :api)
    running = run(context, status: :preparing)

    assert ids(environment: context.staging) == [staging.id]
    assert ids(environment: context.production, statuses: [:failed]) == [failed.id]
    assert ids(trigger: :api) == [api.id]
    assert ids(statuses: [:preparing, :running]) == [running.id]
  end

  test "filters by when the run was queued", context do
    old = run(context, queued_at: ~U[2026-11-01 08:00:00.000000Z])
    middle = run(context, queued_at: ~U[2026-11-03 23:59:59.000000Z])
    _new = run(context, queued_at: ~U[2026-11-04 00:00:00.000000Z])

    assert ids(queued_from: ~U[2026-11-02 00:00:00Z], queued_until: ~U[2026-11-04 00:00:00Z]) ==
             [middle.id]

    assert old.id in ids(queued_until: ~U[2026-11-02 00:00:00Z])
  end

  test "finds runs by deployed version or the start of the commit", context do
    commit = "9fceb02d0ae598e95dc970b74767f19372d61af8"
    deployed = run(context, deployment: %Deployment{version: "1.4.2", commit: commit})
    _other = run(context, deployment: %Deployment{version: "1.4.20"})
    _none = run(context)

    assert ids(deployment: "1.4.2") == [deployed.id]
    assert ids(deployment: "9FCEB02") == [deployed.id]
    assert ids(deployment: " 9fce ") == [deployed.id]
    assert ids(deployment: "1.4") == []
  end

  test "pages by id in both directions", context do
    [a, b, c, d] = for _ <- 1..4, do: run(context)

    assert ids(before: d.id, limit: 2) == [c.id, b.id]
    assert ids(after: a.id, oldest_first: true, limit: 2) == [b.id, c.id]
  end

  test "day_start/2 is midnight in the timezone, in UTC" do
    assert Runs.day_start(~D[2026-11-07], "Europe/Vienna") == ~U[2026-11-06 23:00:00.000000Z]
    assert Runs.day_start(~D[2026-07-07], "Europe/Vienna") == ~U[2026-07-06 22:00:00.000000Z]
  end

  test "matches?/2 agrees with the filters", context do
    run =
      run(context, trigger: :api, deployment: %Deployment{version: "1.4.2", commit: "9fceb02"})

    assert Runs.matches?(run, project: context.project, environment: context.production)
    assert Runs.matches?(run, statuses: [:queued], trigger: :api, deployment: "9fceb")
    assert Runs.matches?(run, queued_from: DateTime.add(run.queued_at, -1), limit: 50)
    refute Runs.matches?(run, environment: context.staging)
    refute Runs.matches?(run, statuses: [:failed])
    refute Runs.matches?(run, trigger: :manual)
    refute Runs.matches?(run, deployment: "1.4")
    refute Runs.matches?(run, queued_until: run.queued_at)
  end
end
