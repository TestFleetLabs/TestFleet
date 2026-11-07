defmodule TestFleet.ResultsHistoryTest do
  # A test across runs: history, streaks, flakiness, and comparing runs (spec section 10).
  use TestFleet.DataCase, async: true

  import TestFleet.EnvironmentsFixtures
  import TestFleet.ProjectsFixtures
  import TestFleet.RunsFixtures
  import TestFleet.TestDefinitionsFixtures

  alias TestFleet.Results
  alias TestFleet.Results.Comparison
  alias TestFleet.Runs

  @pays %{suite: "checkout", classname: "Cart", name: "pays"}

  setup do
    project = project_fixture()
    test_definition = test_definition_fixture(project: project)
    production = environment_fixture(project: project, name: "Production", slug: "production")
    staging = environment_fixture(project: project, name: "Staging", slug: "staging")

    %{test_definition: test_definition, production: production, staging: staging}
  end

  # A finished run of the test definition in production, unless another environment is given.
  defp run(context, tests, opts \\ []) do
    finished_run_fixture(
      Enum.into(opts, %{
        test_definition: context.test_definition,
        environment: Keyword.get(opts, :environment, context.production),
        tests: tests
      })
    )
  end

  # Runs with "pays" passing (true) or failing (false), in order.
  defp sequence(context, outcomes, opts \\ []) do
    Enum.map(outcomes, fn passed? ->
      run(context, [{"pays", if(passed?, do: :passed, else: :failed)}, {"adds", :passed}], opts)
    end)
  end

  describe "test_history/3" do
    test "lists one entry per run, newest first", context do
      first = run(context, [{"pays", :passed}])
      second = run(context, [{"pays", :failed}])
      _other_test = run(context, [{"adds", :passed}])

      assert [newest, oldest] = Results.test_history(context.test_definition, @pays)
      assert %{run_id: id, outcome: :failed, failure_message: "expected 200, got 500"} = newest
      assert id == second.id
      assert %{run_id: id, outcome: :passed, failure_message: nil, cases: 1} = oldest
      assert id == first.id
      assert newest.environment_id == context.production.id
      assert newest.run_status == :failed
      assert newest.image_digest == "sha256:aaa"
    end

    test "combines the cases of one run: error wins, and a retry that passed is mixed",
         context do
      run(context, [{"pays", :failed}, {"pays", :passed}])
      run(context, [{"pays", :failed}, {"pays", :error}])
      run(context, [{"pays", :skipped}, {"pays", :passed}])

      assert [
               %{outcome: :passed, mixed: false, cases: 2},
               %{outcome: :error, mixed: false, cases: 2},
               %{outcome: :failed, mixed: true, cases: 2, duration_ms: 2_000}
             ] = Results.test_history(context.test_definition, @pays)
    end

    test "filters by environment, and pages by run id", context do
      [first, second, third] = sequence(context, [true, false, true])
      run(context, [{"pays", :passed}], environment: context.staging)

      entries =
        Results.test_history(context.test_definition, @pays, environment: context.production)

      assert Enum.map(entries, & &1.run_id) == [third.id, second.id, first.id]

      assert [%{run_id: id}] =
               Results.test_history(context.test_definition, @pays,
                 environment: context.production,
                 before: second.id,
                 limit: 1
               )

      assert id == first.id
    end

    test "only sees the test definition's runs", context do
      other =
        test_definition_fixture(project: Repo.preload(context.test_definition, :project).project)

      run(%{context | test_definition: other}, [{"pays", :failed}])

      assert Results.test_history(context.test_definition, @pays) == []
    end
  end

  describe "failure_streaks/1" do
    test "says whether a failure is new, ongoing, or first seen", context do
      [_passed, first_red, _red] = sequence(context, [true, false, false])
      run(context, [{"adds", :passed}])

      current =
        run(context, [
          {"pays", :failed},
          {"adds", :error},
          {"brand new", :failed},
          {"fine", :passed}
        ])

      assert Results.failure_streaks(current) == %{
               @pays => {:since, first_red.id},
               %{@pays | name: "adds"} => :new,
               %{@pays | name: "brand new"} => :first_seen
             }
    end

    test "leaves out skipped outcomes and other environments", context do
      [first_red] = sequence(context, [false])
      run(context, [{"pays", :skipped}])
      run(context, [{"pays", :passed}], environment: context.staging)

      current = run(context, [{"pays", :failed}])

      assert Results.failure_streaks(current) == %{@pays => {:since, first_red.id}}
    end

    test "is empty for a run without failures", context do
      assert Results.failure_streaks(run(context, [{"pays", :passed}])) == %{}
    end
  end

  describe "flaky_tests/3" do
    test "finds a test that keeps changing on the same image", context do
      runs = sequence(context, [true, false, true, false, true])

      assert [%{test: @pays, flips: 4, runs: 5, last_flip_run_id: last_flip}] =
               Results.flaky_tests(context.test_definition, context.production)

      assert last_flip == List.last(runs).id
    end

    test "a regression and its fix are not flaky", context do
      sequence(context, [true, true, false, false, false, true, true])

      assert Results.flaky_tests(context.test_definition, context.production) == []
    end

    test "a change across an image change is not a flip", context do
      sequence(context, [true], image_digest: "sha256:one")
      sequence(context, [false], image_digest: "sha256:two")
      sequence(context, [true], image_digest: "sha256:three")
      sequence(context, [false], image_digest: "sha256:four")

      assert Results.flaky_tests(context.test_definition, context.production) == []
    end

    test "a run that passed on a retry counts as a flip", context do
      for _ <- 1..3, do: run(context, [{"pays", :failed}, {"pays", :passed}])

      assert [%{test: @pays, flips: 3}] =
               Results.flaky_tests(context.test_definition, context.production)
    end

    test "skipped outcomes and other environments are left out", context do
      for passed? <- [true, false, true, false] do
        run(context, [{"pays", if(passed?, do: :passed, else: :failed)}])
        run(context, [{"pays", :skipped}])
      end

      assert [%{flips: 3, runs: 4}] =
               Results.flaky_tests(context.test_definition, context.production)

      assert Results.flaky_tests(context.test_definition, context.staging) == []
    end

    test "only the latest #{Results.window_size()} runs count", context do
      sequence(context, [true, false, true, false])
      sequence(context, List.duplicate(true, Results.window_size() - 1))

      # The window holds the last of the alternating runs and passes since: 1 flip.
      assert Results.flaky_tests(context.test_definition, context.production) == []
    end

    test "up_to ends the window at a run", context do
      runs = sequence(context, [true, false, true, false])
      sequence(context, List.duplicate(true, Results.window_size()))

      assert [%{flips: 3}] =
               Results.flaky_tests(context.test_definition, context.production,
                 up_to: List.last(runs).id
               )
    end
  end

  describe "test_summary/2" do
    test "describes the test in each environment", context do
      [_, _, _, first_red, _] = sequence(context, [true, false, true, false, false])
      run(context, [{"pays", :passed}], environment: context.staging)

      summaries =
        Map.new(Results.test_summary(context.test_definition, @pays), &{&1.environment_id, &1})

      production = summaries[context.production.id]
      assert production.latest.outcome == :failed
      assert production.streak == %{outcome: :red, count: 2, since_run_id: first_red.id}
      assert production.pass_rate == 0.4
      assert production.flips == 3
      assert production.flaky

      assert Enum.map(production.window, & &1.outcome) == [
               :passed,
               :failed,
               :passed,
               :failed,
               :failed
             ]

      staging = summaries[context.staging.id]
      assert %{outcome: :passed, count: 1} = staging.streak
      assert staging.flips == 0
      refute staging.flaky
    end

    test "is empty for a test without results", context do
      assert Results.test_summary(context.test_definition, @pays) == []
    end
  end

  describe "compare/2" do
    test "groups the tests by how they changed", context do
      baseline =
        run(context, [
          {"breaks", :passed},
          {"heals", :failed},
          {"stays red", :error},
          {"stays green", :passed},
          {"goes away", :passed},
          {"gets skipped", :failed}
        ])

      current =
        run(context, [
          {"breaks", :failed},
          {"heals", :passed},
          {"stays red", :failed},
          {"stays green", :passed},
          {"is new", :passed},
          {"gets skipped", :skipped}
        ])

      comparison = Results.compare(current, baseline)

      names = fn group -> Enum.map(Map.fetch!(comparison, group).tests, & &1.name) end

      assert names.(:new_failures) == ["breaks"]
      assert names.(:fixed) == ["heals"]
      assert names.(:still_failing) == ["stays red"]
      assert names.(:added) == ["is new"]
      assert names.(:removed) == ["goes away"]
      assert comparison.new_failures.total == 1
      assert [%{failure_message: "expected 200, got 500"}] = comparison.new_failures.tests
      assert comparison.run.id == current.id
      assert comparison.baseline.id == baseline.id
    end

    test "lists at most 100 tests per group, with the total" do
      current =
        for i <- 1..120, do: %{suite: "s", classname: "c", name: "t#{i}", outcome: :failed}

      baseline = Enum.map(current, &%{&1 | outcome: :passed})

      %Comparison{new_failures: %{total: 120, tests: tests}} = Comparison.diff(current, baseline)
      assert length(tests) == 100
    end
  end

  describe "Runs.baseline/2 and Runs.comparable/2" do
    test "finds the previous run, or the last one that passed", context do
      passed = run(context, [{"pays", :passed}])
      failed = run(context, [{"pays", :failed}])

      _without_junit =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.production,
          status: :passed
        )

      _other_environment = run(context, [{"pays", :passed}], environment: context.staging)
      current = run(context, [{"pays", :failed}])

      assert Runs.baseline(current, :previous).id == failed.id
      assert Runs.baseline(current, :last_passed).id == passed.id
      assert Runs.baseline(passed, :previous) == nil
    end

    test "says why a run cannot be compared", context do
      current = run(context, [{"pays", :failed}])
      other_environment = run(context, [{"pays", :passed}], environment: context.staging)

      active =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.production,
          status: :running
        )

      without_junit =
        run_fixture(
          test_definition: context.test_definition,
          environment: context.production,
          status: :passed
        )

      other = finished_run_fixture(tests: [{"pays", :passed}])

      assert Runs.comparable(current, other_environment) == :ok
      assert Runs.comparable(current, current) == {:error, :same_run}
      assert Runs.comparable(current, active) == {:error, :not_final}
      assert Runs.comparable(current, without_junit) == {:error, :no_junit}
      assert Runs.comparable(current, other) == {:error, :other_test_definition}
    end
  end
end
