defmodule TestFleetWeb.TestHistoryLiveTest do
  # A test across runs in the UI: failure streaks and the Changes panel on the run
  # page, the test page, and the flaky tests on the test definition page.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  setup :register_and_log_in_user

  setup do
    project = project_fixture()
    test_definition = test_definition_fixture(project: project)
    production = environment_fixture(project: project, name: "Production", slug: "production")
    staging = environment_fixture(project: project, name: "Staging", slug: "staging")

    %{
      project: project,
      test_definition: test_definition,
      production: production,
      staging: staging
    }
  end

  defp run(context, tests, opts \\ []) do
    finished_run_fixture(
      Enum.into(opts, %{
        test_definition: context.test_definition,
        environment: Keyword.get(opts, :environment, context.production),
        tests: tests
      })
    )
  end

  defp alternate(context, count) do
    for i <- 1..count do
      run(context, [{"pays", if(rem(i, 2) == 1, do: :passed, else: :failed)}, {"adds", :passed}])
    end
  end

  defp test_page(context, name, query \\ []) do
    query = [suite: "checkout", classname: "Cart", name: name] ++ query

    ~p"/#{org()}/projects/#{context.project.slug}/test-definitions/#{context.test_definition.id}/tests?#{query}"
  end

  describe "run page: failure streaks" do
    test "mark new, ongoing, first seen, and flaky failures", %{conn: conn} = context do
      alternate(context, 4)
      run(context, [{"pays", :failed}, {"adds", :passed}, {"stays", :failed}])

      current =
        run(context, [
          {"pays", :failed},
          {"adds", :failed},
          {"stays", :failed},
          {"brand new", :error}
        ])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      assert has_element?(view, "#test-failures li[data-test='adds'] [data-streak='new']")
      assert has_element?(view, "#test-failures li[data-test='stays'] [data-streak='since']")

      assert has_element?(
               view,
               "#test-failures li[data-test='brand new'] [data-streak='first-seen']"
             )

      assert has_element?(view, "#test-failures li[data-test='pays'] [data-flaky]")
      refute has_element?(view, "#test-failures li[data-test='adds'] [data-flaky]")
    end

    test "test names link to their test page", %{conn: conn} = context do
      current = run(context, [{"pays", :failed}])
      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")

      assert has_element?(
               view,
               "#test-failures a[data-test-link][href='#{test_page(context, "pays")}']"
             )
    end
  end

  describe "run page: Changes panel" do
    test "compares with the previous run", %{conn: conn} = context do
      baseline = run(context, [{"pays", :passed}, {"adds", :failed}, {"gone", :passed}])
      current = run(context, [{"pays", :failed}, {"adds", :passed}, {"new one", :passed}])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      assert has_element?(
               view,
               "#run-changes-baseline-link[href='/#{org().slug}/runs/#{baseline.id}']"
             )

      assert has_element?(view, "#run-changes-image[data-changed='false']")
      assert has_element?(view, "#run-changes-summary [data-group='new_failures']", "1")
      assert has_element?(view, "#run-changes-new_failures li[data-test='pays']")
      assert has_element?(view, "#run-changes-fixed li[data-test='adds']")
      assert has_element?(view, "#run-changes-added li[data-test='new one']")
      assert has_element?(view, "#run-changes-removed li[data-test='gone']")
      refute has_element?(view, "#run-changes-still_failing")
      assert has_element?(view, "#compare-previous[aria-current='true']")
    end

    test "says when the image changed", %{conn: conn} = context do
      run(context, [{"pays", :passed}], image_digest: "sha256:0123456789abcdef")
      current = run(context, [{"pays", :passed}], image_digest: "sha256:fedcba9876543210")

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      assert has_element?(view, "#run-changes-image[data-changed='true']", "sha256:0123456789ab")
    end

    test "switches to the last passed run", %{conn: conn} = context do
      passed = run(context, [{"pays", :passed}])
      _failed = run(context, [{"pays", :failed}])
      current = run(context, [{"pays", :failed}])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)
      assert has_element?(view, "#run-changes-still_failing")

      view |> element("#compare-last-passed") |> render_click()
      assert_patch(view, ~p"/#{org()}/runs/#{current.id}?compare=last_passed")
      render_async(view)

      assert has_element?(
               view,
               "#run-changes-baseline-link[href='/#{org().slug}/runs/#{passed.id}']"
             )

      assert has_element?(view, "#run-changes-new_failures li[data-test='pays']")
      assert has_element?(view, "#compare-last-passed[aria-current='true']")
    end

    test "compares with any run number, also of another environment", %{conn: conn} = context do
      staging = run(context, [{"pays", :passed}], environment: context.staging)
      current = run(context, [{"pays", :failed}])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      view |> form("#compare-form", %{"run" => "##{staging.id}"}) |> render_submit()
      assert_patch(view, ~p"/#{org()}/runs/#{current.id}?compare=#{staging.id}")
      render_async(view)

      assert has_element?(
               view,
               "#run-changes-baseline-link[href='/#{org().slug}/runs/#{staging.id}']"
             )

      assert has_element?(view, "#run-changes-environment", "Staging")
      assert has_element?(view, "#run-changes-new_failures li[data-test='pays']")
    end

    test "explains a run that cannot be compared and falls back", %{conn: conn} = context do
      previous = run(context, [{"pays", :passed}])
      other = finished_run_fixture(tests: [{"pays", :passed}])
      current = run(context, [{"pays", :failed}])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}?compare=#{other.id}")
      render_async(view)

      assert has_element?(view, "#run-changes-problem", "another test definition")

      assert has_element?(
               view,
               "#run-changes-baseline-link[href='/#{org().slug}/runs/#{previous.id}']"
             )

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}?compare=999999999")
      render_async(view)
      assert has_element?(view, "#run-changes-problem", "no such run")
    end

    test "says when there is nothing to compare with", %{conn: conn} = context do
      current = run(context, [{"pays", :failed}])

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      assert has_element?(view, "#run-changes-none")
    end

    test "is not shown without JUnit", %{conn: conn} = context do
      current =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.production,
          status: :passed
        )

      {:ok, view, _html} = live(conn, ~p"/#{org()}/runs/#{current.id}")
      render_async(view)

      refute has_element?(view, "#run-changes")
    end
  end

  describe "test page" do
    test "shows the test in each environment", %{conn: conn} = context do
      runs = alternate(context, 5)
      run(context, [{"pays", :failed}], environment: context.staging)

      {:ok, view, _html} = live(conn, test_page(context, "pays"))

      assert has_element?(view, "#test-name", "pays")
      assert has_element?(view, "#test-location", "checkout › Cart")
      assert has_element?(view, "#test-environment-production-latest[data-outcome='passed']")
      assert has_element?(view, "#test-environment-production-streak", "Passing for 1 run")
      assert has_element?(view, "#test-environment-production-pass-rate", "60%")
      assert has_element?(view, "#test-environment-production-flips", "4")
      assert has_element?(view, "#test-environment-production [data-flaky]")
      assert has_element?(view, "#test-environment-staging-streak", "Failing for 1 run")
      refute has_element?(view, "#test-environment-staging [data-flaky]")

      # Without an environment chosen, no strip: the history of all environments.
      refute has_element?(view, "#test-outcomes")
      assert has_element?(view, "#history-tab-all[aria-current='true']")

      for run <- runs do
        assert has_element?(view, "#history-#{run.id}")
      end
    end

    test "an environment shows its outcome strip and only its history", %{conn: conn} = context do
      [first | _] = runs = alternate(context, 3)
      staging = run(context, [{"pays", :passed}], environment: context.staging)

      {:ok, view, _html} = live(conn, test_page(context, "pays"))
      view |> element("#test-environment-production") |> render_click()
      assert_patch(view, test_page(context, "pays", env: "production"))

      assert has_element?(view, "#test-environment-production[aria-current='true']")
      assert has_element?(view, "#outcome-#{first.id} a[data-outcome='passed']")
      assert has_element?(view, "#outcome-#{Enum.at(runs, 1).id} a[data-outcome='failed']")
      refute has_element?(view, "#outcome-#{staging.id}")
      refute has_element?(view, "#history-#{staging.id}")
      assert has_element?(view, "#history-#{first.id}[data-outcome='passed']")
    end

    test "shows a retry that passed", %{conn: conn} = context do
      mixed = run(context, [{"pays", :failed}, {"pays", :passed}])

      {:ok, view, _html} = live(conn, test_page(context, "pays", env: "production"))

      assert has_element?(view, "#outcome-#{mixed.id} a[data-mixed='true']")
      assert has_element?(view, "#history-#{mixed.id}", "passed on retry")
      assert has_element?(view, "#history-#{mixed.id}", "2 cases")
      assert has_element?(view, "#history-#{mixed.id} [data-failure-message]", "expected 200")
    end

    test "loads more history", %{conn: conn} = context do
      runs = for _ <- 1..51, do: run(context, [{"pays", :passed}])

      {:ok, view, _html} = live(conn, test_page(context, "pays"))

      refute has_element?(view, "#history-#{hd(runs).id}")
      view |> element("#history-more") |> render_click()
      assert has_element?(view, "#history-#{hd(runs).id}")
      refute has_element?(view, "#history-more")
    end

    test "adds a run that finishes while the page is open", %{conn: conn} = context do
      run(context, [{"pays", :passed}])
      {:ok, view, _html} = live(conn, test_page(context, "pays"))

      later = run(context, [{"pays", :failed}])

      assert has_element?(view, "#history-#{later.id}[data-outcome='failed']")
      assert has_element?(view, "#test-environment-production-streak", "Failing for 1 run")
    end

    test "a test without results says so", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, test_page(context, "never ran"))

      assert has_element?(view, "#test-no-results")
      refute has_element?(view, "#test-history")
    end
  end

  describe "test definition page: flaky tests" do
    defp definition_page(context),
      do:
        ~p"/#{org()}/projects/#{context.project.slug}/test-definitions/#{context.test_definition.id}"

    test "lists the flaky tests of the first environment", %{conn: conn} = context do
      runs = alternate(context, 5)

      {:ok, view, _html} = live(conn, definition_page(context))
      render_async(view)

      assert has_element?(
               view,
               "#flaky-test-0 a[data-test-link][href='#{test_page(context, "pays")}']"
             )

      assert has_element?(view, "#flaky-test-0 [data-flips]", "4 flips")

      assert has_element?(
               view,
               "#flaky-test-0 a[href='/#{org().slug}/runs/#{List.last(runs).id}']"
             )

      refute has_element?(view, "#flaky-test-1")
    end

    test "switches between environments", %{conn: conn} = context do
      alternate(context, 5)

      {:ok, view, _html} = live(conn, definition_page(context))
      render_async(view)
      assert has_element?(view, "#flaky-test-0")

      view |> element("#flaky-environment-#{context.staging.id}") |> render_click()
      render_async(view)

      assert has_element?(view, "#flaky-environment-#{context.staging.id}[aria-pressed='true']")
      assert has_element?(view, "#flaky-tests-none")
    end
  end
end
