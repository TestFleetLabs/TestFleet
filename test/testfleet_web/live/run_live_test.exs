defmodule TestFleetWeb.RunLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Runs

  setup :register_and_log_in_user

  setup do
    project = project_fixture(%{name: "Customer Portal"})

    %{
      project: project,
      test_definition:
        test_definition_fixture(
          project: project,
          name: "Checkout",
          image: "e2e:1.17",
          command: ["./run-e2e.sh"],
          memory_limit: 4 * 1024 * 1024 * 1024
        ),
      environment: environment_fixture(project: project, name: "Production")
    }
  end

  defp test_definition_path(%{test_definition: test_definition}),
    do: ~p"/projects/customer-portal/test-definitions/#{test_definition.id}"

  describe "test definition page" do
    test "shows the settings and links to the edit form", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, test_definition_path(context))

      assert has_element?(view, "#test-definition-settings", "e2e:1.17")
      assert has_element?(view, "#test-definition-settings", "./run-e2e.sh")
      assert has_element?(view, "#test-definition-settings", "4 GiB")

      assert has_element?(
               view,
               "#edit-test-definition[href='#{test_definition_path(context)}/edit']"
             )
    end

    test "the project page links to it", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      assert has_element?(
               view,
               "#test_definitions-#{context.test_definition.id} a[href='#{test_definition_path(context)}']"
             )
    end

    test "Run now creates a queued run and opens it", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, test_definition_path(context))

      {:ok, run_view, _html} =
        view
        |> element("#run-now-#{context.environment.id}")
        |> render_click()
        |> follow_redirect(conn)

      assert [run] = Runs.list_runs(test_definition: context.test_definition)
      assert %{status: :queued, trigger: :manual, image: "e2e:1.17"} = run
      assert has_element?(run_view, "#run-status[data-status='queued']")

      # Who started it (Milestone 10, section 6)
      assert run.triggered_by_user_id == context.user.id
      assert has_element?(run_view, "#run-triggered-by", context.user.email)
    end

    test "cannot run a disabled test definition", %{conn: conn} = context do
      {:ok, _} =
        TestFleet.TestDefinitions.update_test_definition(context.test_definition, %{
          enabled: false
        })

      {:ok, view, _html} = live(conn, test_definition_path(context))

      assert has_element?(view, "#run-now-disabled")
      assert has_element?(view, "#run-now-#{context.environment.id}[disabled]")
    end

    test "explains when there is no environment", %{conn: conn} do
      project = project_fixture(%{name: "Billing"})
      test_definition = test_definition_fixture(project: project)

      {:ok, view, _html} =
        live(conn, ~p"/projects/billing/test-definitions/#{test_definition.id}")

      assert has_element?(view, "#run-now-no-environments")
    end

    test "lists its runs and adds new ones live", %{conn: conn} = context do
      old = run_fixture(test_definition: context.test_definition, status: :passed)
      other = run_fixture()

      {:ok, view, _html} = live(conn, test_definition_path(context))
      assert has_element?(view, "#runs-#{old.id}")
      refute has_element?(view, "#runs-#{other.id}")

      {:ok, new} = Runs.create_manual_run(context.test_definition, context.environment)
      assert has_element?(view, "#runs-#{new.id}")
    end

    test "a test definition of another project is not found", %{conn: conn} do
      other = test_definition_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        live(conn, ~p"/projects/customer-portal/test-definitions/#{other.id}")
      end
    end
  end

  describe "run page" do
    test "shows what the run executes", %{conn: conn} = context do
      run =
        run_fixture(test_definition: context.test_definition, environment: context.environment)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-status[data-status='queued']")
      assert has_element?(view, "#run-test-definition[href='#{test_definition_path(context)}']")
      assert has_element?(view, "#run-environment", "Production")
      assert has_element?(view, "#run-execution", "e2e:1.17")
      assert has_element?(view, "#cancel-run")
    end

    test "cancels a queued run", %{conn: conn} = context do
      run = run_fixture(test_definition: context.test_definition)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      view |> element("#cancel-run") |> render_click()

      assert has_element?(view, "#run-status[data-status='cancelled']")
      refute has_element?(view, "#cancel-run")
      assert %{status: :cancelled} = Runs.get_run!(run.id)
    end

    test "an active run shows it is cancelling until the final status arrives",
         %{conn: conn} = context do
      run = run_fixture(test_definition: context.test_definition, status: :running)

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")
      view |> element("#cancel-run") |> render_click()

      assert has_element?(view, "#cancelling-run[disabled]")
      refute has_element?(view, "#cancel-run")
      assert has_element?(view, "#run-status[data-status='running']")

      # The request is stored, so a reload still shows it.
      {:ok, reloaded, _html} = live(conn, ~p"/runs/#{run.id}")
      assert has_element?(reloaded, "#cancelling-run[disabled]")

      # What the recorder does once the container has stopped.
      {:ok, _} =
        Runs.finish(run.id, %TestFleet.Execution.Result{
          run_id: run.id,
          status: :cancelled,
          finished_at: DateTime.utc_now()
        })

      assert has_element?(view, "#run-status[data-status='cancelled']")
      refute has_element?(view, "#cancelling-run")
    end

    test "updates live", %{conn: conn} = context do
      run = run_fixture(test_definition: context.test_definition)
      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      :ok = Runs.cancel_run(run)
      assert has_element?(view, "#run-status[data-status='cancelled']")
    end

    test "shows the outcome of a finished run", %{conn: conn} = context do
      started_at = ~U[2026-09-27 06:00:00.000000Z]

      run =
        run_fixture(
          test_definition: context.test_definition,
          status: :error,
          image_digest: "e2e@sha256:abc",
          started_at: started_at,
          finished_at: DateTime.add(started_at, 257, :second),
          exit_code: 137,
          oom_killed: true,
          error_message: "memory limit exceeded"
        )

      {:ok, view, _html} = live(conn, ~p"/runs/#{run.id}")

      assert has_element?(view, "#run-status[data-status='error']")
      assert has_element?(view, "#run-error", "memory limit exceeded")
      assert has_element?(view, "#run-digest", "e2e@sha256:abc")
      assert has_element?(view, "#run-exit-code", "137")
      assert has_element?(view, "#run-duration", "4m 17s")
      refute has_element?(view, "#cancel-run")
    end
  end

  describe "runs list" do
    test "lists runs and adds new ones live", %{conn: conn} = context do
      run = run_fixture(test_definition: context.test_definition)

      {:ok, view, _html} = live(conn, ~p"/runs")
      assert has_element?(view, "#runs-#{run.id} a[href='/runs/#{run.id}']")
      assert has_element?(view, "#runs-#{run.id}", "Checkout")

      {:ok, new} = Runs.create_manual_run(context.test_definition, context.environment)
      assert has_element?(view, "#runs-#{new.id}")

      :ok = Runs.cancel_run(new)
      assert has_element?(view, "#runs-#{new.id} [data-status='cancelled']")
    end
  end

  describe "project page" do
    test "shows the project's recent runs, live", %{conn: conn} = context do
      other_project_run = run_fixture()
      run = run_fixture(test_definition: context.test_definition)

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")
      assert has_element?(view, "#recent-run-list #runs-#{run.id}")
      refute has_element?(view, "#runs-#{other_project_run.id}")

      {:ok, new} = Runs.create_manual_run(context.test_definition, context.environment)
      assert has_element?(view, "#recent-run-list #runs-#{new.id}")

      :ok = Runs.cancel_run(other_project_run)
      refute has_element?(view, "#runs-#{other_project_run.id}")
    end

    test "keeps the latest 10 when an older run changes", %{conn: conn} = context do
      [oldest | _] = for _ <- 1..10, do: run_fixture(test_definition: context.test_definition)

      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")
      assert has_element?(view, "#runs-#{oldest.id}")

      {:ok, new} = Runs.create_manual_run(context.test_definition, context.environment)
      assert has_element?(view, "#runs-#{new.id}")
      refute has_element?(view, "#runs-#{oldest.id}")

      # An update of a run that dropped off the list must not bring it back.
      :ok = Runs.cancel_run(oldest)
      refute has_element?(view, "#runs-#{oldest.id}")
    end

    test "shows an empty state without runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")
      assert has_element?(view, "#recent-runs-empty-state")
    end
  end

  describe "deleting configuration with runs" do
    setup context do
      %{
        run:
          run_fixture(test_definition: context.test_definition, environment: context.environment)
      }
    end

    test "a test definition shows why it cannot be deleted", %{conn: conn} = context do
      {:ok, view, _html} = live(conn, "#{test_definition_path(context)}/edit")

      view |> element("#delete-test-definition") |> render_click()
      assert has_element?(view, "#flash-error", "has runs")
      assert TestFleet.TestDefinitions.list_test_definitions(context.project) != []
    end

    test "an environment shows why it cannot be deleted", %{conn: conn} = context do
      {:ok, view, _html} =
        live(conn, ~p"/projects/customer-portal/environments/#{context.environment.slug}")

      view |> element("#delete-environment") |> render_click()
      assert has_element?(view, "#flash-error", "has runs")
    end

    test "a project shows why it cannot be deleted", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/projects/customer-portal")

      view |> element("#delete-project") |> render_click()
      assert has_element?(view, "#flash-error", "has runs")
    end
  end
end
