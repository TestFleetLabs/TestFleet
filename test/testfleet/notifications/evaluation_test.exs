defmodule TestFleet.Notifications.EvaluationTest do
  # Milestone 8, section 6: evaluating final runs, and who gets the delivery.
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.NotificationsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Execution.Result
  alias TestFleet.Notifications
  alias TestFleet.Notifications.{Delivery, DeliveryWorker, EvaluateWorker, Message}
  alias TestFleet.Runs

  setup do
    project = project_fixture(name: "Customer Portal")

    %{
      project: project,
      test_definition: test_definition_fixture(project: project, name: "Portal E2E"),
      environment: environment_fixture(project: project, name: "production")
    }
  end

  defp run(context, status, attrs \\ []) do
    run_fixture(
      [test_definition: context.test_definition, environment: context.environment, status: status] ++
        attrs
    )
  end

  defp subscribe(channel, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{"events" => ["run.failing", "run.recovered", "run.error"]},
        Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      )

    {:ok, subscription} = Notifications.create_subscription(channel, attrs)
    subscription
  end

  defp evaluated_jobs(run_id) do
    for job <- all_enqueued(worker: EvaluateWorker), job.args["run_id"] == run_id, do: job
  end

  describe "every path that makes a run final inserts the evaluation" do
    test "finish", context do
      run = run(context, :running)

      {:ok, _} =
        Runs.finish(run.id, %Result{
          run_id: run.id,
          status: :failed,
          finished_at: DateTime.utc_now()
        })

      assert [_] = evaluated_jobs(run.id)
    end

    test "fail", context do
      run = run(context, :preparing)
      {:ok, _} = Runs.fail(run.id, "image not found")
      assert [_] = evaluated_jobs(run.id)
    end

    test "cancelling a queued run", context do
      run = run(context, :queued)
      :ok = Runs.cancel_run(run)
      assert [_] = evaluated_jobs(run.id)
    end

    test "mark_cancelled", context do
      run = run(context, :running)
      {:ok, _} = Runs.mark_cancelled(run.id)
      assert [_] = evaluated_jobs(run.id)
    end

    test "but not a change that leaves the run active", context do
      run = run(context, :preparing)
      {:ok, _} = Runs.mark_running(run.id, DateTime.utc_now())
      assert evaluated_jobs(run.id) == []
    end

    test "and a repeated finish inserts nothing more", context do
      run = run(context, :running)
      result = %Result{run_id: run.id, status: :passed, finished_at: DateTime.utc_now()}
      {:ok, _} = Runs.finish(run.id, result)
      :error = Runs.finish(run.id, result)
      assert [_] = evaluated_jobs(run.id)
    end
  end

  describe "evaluate_run/1" do
    test "a failing series notifies each subscribed channel once", context do
      slack = channel_fixture()
      email = channel_fixture(kind: :email)
      # Two subscriptions of one channel that both match: still one delivery.
      subscribe(slack)
      subscribe(slack, project_id: context.project.id)
      subscribe(email, project_id: context.project.id, environment_id: context.environment.id)

      previous = run(context, :passed)
      failed = run(context, :failed)

      assert {:ok, deliveries} = Notifications.evaluate_run(failed.id)

      assert Enum.map(deliveries, & &1.channel_id) |> Enum.sort() ==
               Enum.sort([slack.id, email.id])

      for delivery <- deliveries do
        assert %Delivery{event: "run.failing", run_id: run_id, status: :pending} = delivery
        assert run_id == failed.id
        assert delivery.data == %{"previous_status" => "passed", "previous_run_id" => previous.id}
      end

      assert length(all_enqueued(worker: DeliveryWorker)) == 2
    end

    test "evaluating again delivers nothing new", context do
      subscribe(channel_fixture())
      failed = run(context, :failed)

      {:ok, [_]} = Notifications.evaluate_run(failed.id)
      assert {:ok, []} = Notifications.evaluate_run(failed.id)
      assert Repo.aggregate(Delivery, :count) == 1
    end

    test "no event, no delivery", context do
      subscribe(channel_fixture())
      run(context, :failed)
      still_failing = run(context, :failed)

      assert {:ok, []} = Notifications.evaluate_run(still_failing.id)
    end

    test "events a subscription did not choose are not delivered", context do
      subscribe(channel_fixture(), events: ["run.error"])
      failed = run(context, :failed)

      assert {:ok, []} = Notifications.evaluate_run(failed.id)
    end

    test "another project or environment is out of scope", context do
      other_project = project_fixture()
      other_environment = environment_fixture(project: context.project)
      subscribe(channel_fixture(), project_id: other_project.id)

      subscribe(channel_fixture(),
        project_id: context.project.id,
        environment_id: other_environment.id
      )

      failed = run(context, :failed)
      assert {:ok, []} = Notifications.evaluate_run(failed.id)
    end

    test "disabled channels get nothing", context do
      channel = channel_fixture()
      subscribe(channel)
      {:ok, _} = Notifications.set_channel_enabled(channel, false)

      assert {:ok, []} = Notifications.evaluate_run(run(context, :failed).id)
    end

    test "series are per environment", context do
      subscribe(channel_fixture())
      staging = environment_fixture(project: context.project)
      run(context, :failed, environment: staging)

      # Failing on staging says nothing about production.
      assert {:ok, [_]} = Notifications.evaluate_run(run(context, :failed).id)
    end
  end

  describe "run messages" do
    test "failing names the first failed tests, never their messages", context do
      run =
        run(context, :running,
          trigger: :schedule,
          started_at: ~U[2026-09-28 14:00:00.000000Z]
        )

      test_case = fn name, status ->
        %{
          suite: "s",
          classname: "checkout",
          name: name,
          status: status,
          duration_ms: 1,
          failure_message: "expected 200, got 500 at https://internal/token=abc",
          failure_details: "stack",
          file: "junit.xml"
        }
      end

      {:ok, _} =
        Runs.finish(run.id, %Result{
          run_id: run.id,
          status: :failed,
          exit_code: 1,
          finished_at: ~U[2026-09-28 14:04:12.000000Z],
          test_results: [
            test_case.("pays with card", :failed),
            test_case.("pays with invoice", :failed),
            test_case.("shows the cart", :passed),
            test_case.("applies a voucher", :error),
            test_case.("ships abroad", :failed)
          ]
        })

      delivery = %Delivery{
        event: "run.failing",
        run_id: run.id,
        data: %{"previous_status" => "passed", "previous_run_id" => 7}
      }

      message = Notifications.run_message(delivery)

      assert message.title == "Portal E2E is failing on production"
      assert message.summary == "4 of 5 tests failed."
      facts = Map.new(message.facts)
      assert facts["Project"] == "Customer Portal"
      assert facts["Trigger"] == "Scheduled"
      assert facts["Duration"] == "4 min 12 s"
      assert facts["Tests"] == "1 passed, 4 failed"
      assert facts["Previous run"] == "passed (#7)"

      assert facts["First failures"] ==
               "checkout › pays with card, checkout › pays with invoice, checkout › applies a voucher and 1 more"

      assert message.link.url =~ "/runs/#{run.id}"

      refute inspect(message) =~ "expected 200"
      refute inspect(message) =~ "token=abc"

      assert %{"run" => %{"id" => id, "status" => "failed", "tests" => %{"failed" => 4}}} =
               message.payload

      assert id == run.id
      assert message.payload["environment"]["name"] == "production"
    end

    test "timeout, recovered, and error read differently", context do
      render = fn event, run ->
        Notifications.run_message(%Delivery{event: event, run_id: run.id, data: %{}})
      end

      timeout = run(context, :timeout)

      assert %Message{title: "Portal E2E timed out on production"} =
               render.("run.failing", timeout)

      passed = run(context, :passed, tests_passed: 12, tests_failed: 0, tests_skipped: 0)

      assert %Message{
               title: "Portal E2E recovered on production",
               summary: "All 12 tests passed."
             } =
               render.("run.recovered", passed)

      error = run(context, :error, error_message: "manifest unknown")

      assert %Message{
               title: "Portal E2E could not run on production",
               summary: "manifest unknown"
             } =
               render.("run.error", error)
    end

    test "the delivery worker sends a run event", context do
      test = self()

      Req.Test.stub(TestFleet.Notifications, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:body, Jason.decode!(body)})
        Req.Test.text(conn, "ok")
      end)

      subscribe(channel_fixture(kind: :webhook))
      {:ok, [delivery]} = Notifications.evaluate_run(run(context, :failed).id)

      assert :ok = perform_job(DeliveryWorker, %{delivery_id: delivery.id})
      assert %Delivery{status: :sent} = Repo.get!(Delivery, delivery.id)

      assert_received {:body, %{"event" => "run.failing", "delivery_id" => id, "run" => %{}}}
      assert id == delivery.id
    end
  end

  describe "subscriptions" do
    test "system events only without a project", context do
      channel = channel_fixture()

      assert {:ok, _} =
               Notifications.create_subscription(channel, %{
                 "events" => ["system.docker_unreachable"]
               })

      assert {:error, changeset} =
               Notifications.create_subscription(channel, %{
                 "project_id" => context.project.id,
                 "events" => ["system.docker_unreachable"]
               })

      assert "system events are only for all projects" in errors_on(changeset).events
    end

    test "at least one known event", context do
      channel = channel_fixture()

      assert {:error, changeset} = Notifications.create_subscription(channel, %{"events" => [""]})
      assert "choose at least one event" in errors_on(changeset).events

      assert {:error, changeset} =
               Notifications.create_subscription(channel, %{"events" => ["run.exploded"]})

      assert errors_on(changeset).events != []
      _ = context
    end

    test "an environment belongs to the chosen project", context do
      channel = channel_fixture()
      other = environment_fixture(project: project_fixture())

      assert {:error, changeset} =
               Notifications.create_subscription(channel, %{
                 "project_id" => context.project.id,
                 "environment_id" => other.id,
                 "events" => ["run.failing"]
               })

      assert "does not belong to the project" in errors_on(changeset).environment_id

      assert {:error, changeset} =
               Notifications.create_subscription(channel, %{
                 "environment_id" => context.environment.id,
                 "events" => ["run.failing"]
               })

      assert "needs a project" in errors_on(changeset).environment_id
    end
  end
end
