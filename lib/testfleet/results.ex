defmodule TestFleet.Results do
  @moduledoc """
  Test results parsed from a run's JUnit report.

  `TestFleet.Results.JUnit` parses during execution; `Runs.finish/2` stores the
  rows with the run's final status.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Environments.Environment
  alias TestFleet.Repo
  alias TestFleet.Results.{Comparison, TestResult}
  alias TestFleet.Runs.Run
  alias TestFleet.TestDefinitions.TestDefinition

  @chunk_size 1_000

  @failures [:failed, :error]

  # A test across runs (spec section 10)
  @window 30
  @flaky_flips 3
  @flaky_limit 50
  @history_limit 50
  @outcomes %{"passed" => :passed, "failed" => :failed, "error" => :error, "skipped" => :skipped}

  # One outcome per identity and run: error wins over failed, failed over passed.
  defmacrop outcome(status) do
    quote do
      fragment(
        "CASE WHEN bool_or(? = 'error') THEN 'error' WHEN bool_or(? = 'failed') THEN 'failed' WHEN bool_or(? = 'passed') THEN 'passed' ELSE 'skipped' END",
        unquote(status),
        unquote(status),
        unquote(status)
      )
    end
  end

  # Passed and red in the same run: the test passed on a retry.
  defmacrop mixed(status) do
    quote do
      fragment(
        "(bool_or(? = 'passed') AND bool_or(? IN ('failed', 'error')))",
        unquote(status),
        unquote(status)
      )
    end
  end

  defmacrop first_failure_message(result) do
    quote do
      fragment(
        "(array_agg(? ORDER BY ?) FILTER (WHERE ? IS NOT NULL))[1]",
        field(unquote(result), :failure_message),
        field(unquote(result), :id),
        field(unquote(result), :failure_message)
      )
    end
  end

  # A step of a test's outcome sequence: 1 for a mixed run, plus 1 for a change
  # between passed and red since the previous outcome on the same image digest.
  defmacrop flip(step) do
    quote do
      fragment(
        "((CASE WHEN ? THEN 1 ELSE 0 END) + (CASE WHEN ? IS NOT NULL AND (? = 'passed') <> (? = 'passed') AND ? IS NOT DISTINCT FROM ? THEN 1 ELSE 0 END))",
        field(unquote(step), :mixed),
        field(unquote(step), :prev_outcome),
        field(unquote(step), :outcome),
        field(unquote(step), :prev_outcome),
        field(unquote(step), :image_digest),
        field(unquote(step), :prev_digest)
      )
    end
  end

  @doc """
  A run's test results: failed and errored first, then in report order.

  `only: :failures` returns the failed and errored ones, `only: :others` the rest;
  the run page loads the rest on demand.
  """
  def list_test_results(%Run{id: run_id}, opts \\ []) do
    query =
      from t in TestResult,
        where: t.run_id == ^run_id,
        order_by: [
          asc: fragment("CASE WHEN ? IN ('failed', 'error') THEN 0 ELSE 1 END", t.status),
          asc: t.id
        ]

    query =
      case opts[:only] do
        nil -> query
        :failures -> where(query, [t], t.status in ^@failures)
        :others -> where(query, [t], t.status not in ^@failures)
      end

    Repo.all(query)
  end

  @doc """
  The names of a run's first `limit` failed or errored tests, as
  `"<classname> › <name>"`, and how many failed in all. Names only: failure
  messages stay on the run page.
  """
  def failure_summary(%Run{id: run_id}, limit \\ 3) do
    failures = from t in TestResult, where: t.run_id == ^run_id and t.status in ^@failures

    names =
      Repo.all(
        from t in failures, order_by: [asc: t.id], limit: ^limit, select: {t.classname, t.name}
      )
      |> Enum.map(fn
        {classname, name} when classname in [nil, ""] -> name
        {classname, name} -> "#{classname} › #{name}"
      end)

    %{names: names, count: Repo.aggregate(failures, :count)}
  end

  @doc "The sum of a run's test durations in milliseconds; `nil` without any."
  def total_duration_ms(%Run{id: run_id}) do
    Repo.one(from t in TestResult, where: t.run_id == ^run_id, select: sum(t.duration_ms))
  end

  @doc """
  The counts stored on a run: `tests_failed` includes errors. All `nil` without
  JUnit (`test_results` is `nil`).
  """
  def counts(nil), do: %{tests_passed: nil, tests_failed: nil, tests_skipped: nil}

  def counts(test_results) do
    frequencies = Enum.frequencies_by(test_results, & &1.status)

    %{
      tests_passed: Map.get(frequencies, :passed, 0),
      tests_failed: Map.get(frequencies, :failed, 0) + Map.get(frequencies, :error, 0),
      tests_skipped: Map.get(frequencies, :skipped, 0)
    }
  end

  @doc """
  Inserts parsed test cases (see `TestFleet.Results.JUnit`, plus `file`), in chunks
  of #{@chunk_size}. Called by `Runs.finish/2` inside its transaction.
  """
  def insert_all(_run, nil), do: :ok

  def insert_all(%Run{id: run_id, test_definition_id: test_definition_id}, test_results) do
    now = DateTime.utc_now()

    test_results
    |> Enum.map(fn result ->
      result
      |> Map.take([
        :suite,
        :classname,
        :name,
        :status,
        :duration_ms,
        :failure_message,
        :failure_details,
        :file
      ])
      |> Map.merge(%{run_id: run_id, test_definition_id: test_definition_id, inserted_at: now})
    end)
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(&Repo.insert_all(TestResult, &1))
  end

  ## A test across runs

  @doc "How many runs of a test definition and environment the flakiness window holds."
  def window_size, do: @window

  @doc "The number of flips in the window from which a test counts as flaky."
  def flaky_flips, do: @flaky_flips

  @doc "A test's identity within its test definition: `%{suite, classname, name}`."
  def test_of(%{suite: suite, classname: classname, name: name}),
    do: %{suite: suite, classname: classname, name: name}

  @doc """
  A test's history: one entry per run that reported it, newest first, with the
  run's id, status, environment id, image digest, and `finished_at`, the outcome,
  `mixed` (passed on a retry), the number of `cases`, their summed `duration_ms`,
  and the first `failure_message`.

  Options: `:environment`, `:before` (a run id, for paging), and `:limit`
  (default #{@history_limit}).
  """
  def test_history(%TestDefinition{id: id}, test, opts \\ []) do
    environment_id =
      case opts[:environment] do
        %Environment{id: environment_id} -> environment_id
        nil -> nil
      end

    id
    |> history_query(test, environment_id, opts)
    |> Repo.all()
    |> Enum.map(&cast_outcome/1)
  end

  defp history_query(test_definition_id, test, environment_id, opts) do
    query =
      from t in TestResult,
        as: :result,
        join: r in Run,
        as: :run,
        on: r.id == t.run_id,
        where: t.test_definition_id == ^test_definition_id,
        group_by: r.id,
        order_by: [desc: r.id],
        limit: ^Keyword.get(opts, :limit, @history_limit),
        select: %{
          run_id: r.id,
          run_status: r.status,
          environment_id: r.environment_id,
          image_digest: r.image_digest,
          finished_at: r.finished_at,
          outcome: outcome(t.status),
          mixed: mixed(t.status),
          cases: count(t.id),
          duration_ms: sum(t.duration_ms),
          failure_message: first_failure_message(t)
        }

    query = for_test(query, test)
    query = if environment_id, do: in_environment(query, environment_id), else: query
    query = if before = opts[:before], do: where(query, [run: r], r.id < ^before), else: query

    if opts[:window],
      do: in_window(query, test_definition_id, environment_id, nil),
      else: query
  end

  @doc """
  A test's state in each environment that reported it:

  - `environment_id`
  - `latest`: its latest history entry (see `test_history/3`)
  - `window`: its history entries in the flakiness window, oldest first
  - `pass_rate`: passed among the window's outcomes that are not skipped, or nil
  - `streak`: `%{outcome: :passed | :red, count: n, since_run_id: id}`, or nil when
    it was only ever skipped
  - `flips`, and `flaky` (at least #{@flaky_flips} flips)
  """
  def test_summary(%TestDefinition{id: id}, test) do
    environment_ids =
      from(t in TestResult,
        as: :result,
        join: r in Run,
        as: :run,
        on: r.id == t.run_id,
        where: t.test_definition_id == ^id,
        distinct: true,
        select: r.environment_id
      )
      |> for_test(test)
      |> Repo.all()

    Enum.map(environment_ids, fn environment_id ->
      window =
        id
        |> history_query(test, environment_id, window: true)
        |> Repo.all()
        |> Enum.map(&cast_outcome/1)
        |> Enum.reverse()

      [latest] =
        id
        |> history_query(test, environment_id, limit: 1)
        |> Repo.all()
        |> Enum.map(&cast_outcome/1)

      streak =
        id |> outcomes() |> for_test(test) |> in_environment(environment_id) |> streaks()

      flips =
        case Repo.one(flips_query(id, environment_id, test: test)) do
          nil -> 0
          %{flips: flips} -> flips
        end

      counted = Enum.count(window, &(&1.outcome != :skipped))
      passed = Enum.count(window, &(&1.outcome == :passed))

      %{
        environment_id: environment_id,
        latest: latest,
        window: window,
        pass_rate: if(counted > 0, do: passed / counted),
        streak: streak |> Repo.one() |> streak_of(),
        flips: flips,
        flaky: flips >= @flaky_flips
      }
    end)
  end

  defp streak_of(nil), do: nil

  defp streak_of(%{last_pass: last_pass, last_red: last_red, since: since, count: count}) do
    %{
      outcome: if(passing?(last_pass, last_red), do: :passed, else: :red),
      count: count,
      since_run_id: since
    }
  end

  @doc """
  The flaky tests of a test definition in an environment: at least
  #{@flaky_flips} flips in the latest #{@window} runs with JUnit. Each is
  `%{test, flips, runs, last_flip_run_id}`, `runs` being the window's runs that
  reported it. Most flips first, then the most recent flip.

  Options: `:up_to` (a run id: the window ends there) and `:limit` (default
  #{@flaky_limit}; `nil` for all).
  """
  def flaky_tests(%TestDefinition{id: id}, %Environment{id: environment_id}, opts \\ []) do
    query =
      from [s] in flips_query(id, environment_id, opts),
        having: sum(flip(s)) >= ^@flaky_flips,
        order_by: [
          desc: sum(flip(s)),
          desc: max(fragment("CASE WHEN ? > 0 THEN ? END", flip(s), s.run_id))
        ]

    query =
      case Keyword.get(opts, :limit, @flaky_limit) do
        nil -> query
        limit -> limit(query, ^limit)
      end

    query
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        test: test_of(row),
        flips: row.flips,
        runs: row.runs,
        last_flip_run_id: row.last_flip_run_id
      }
    end)
  end

  # The flips of each test in the window, in one query: the outcomes not skipped,
  # each next to the previous one (`lag()`), summed per identity.
  defp flips_query(test_definition_id, environment_id, opts) do
    base =
      test_definition_id
      |> outcomes()
      |> in_environment(environment_id)
      |> in_window(test_definition_id, environment_id, opts[:up_to])

    base = if test = opts[:test], do: for_test(base, test), else: base

    sequence =
      from o in subquery(base),
        where: o.outcome != "skipped",
        windows: [w: [partition_by: [o.suite, o.classname, o.name], order_by: o.run_id]],
        select: %{
          suite: o.suite,
          classname: o.classname,
          name: o.name,
          run_id: o.run_id,
          outcome: o.outcome,
          mixed: o.mixed,
          image_digest: o.image_digest,
          prev_outcome: over(lag(o.outcome), :w),
          prev_digest: over(lag(o.image_digest), :w)
        }

    from s in subquery(sequence),
      group_by: [s.suite, s.classname, s.name],
      select: %{
        suite: s.suite,
        classname: s.classname,
        name: s.name,
        flips: sum(flip(s)),
        runs: count(),
        last_flip_run_id: max(fragment("CASE WHEN ? > 0 THEN ? END", flip(s), s.run_id))
      }
  end

  @doc """
  For each red test of a run (a `test_of/1` map), how long it has been red in the
  run's environment: `:new` (it passed before), `{:since, run_id}` (the first run
  of its unbroken red series), or `:first_seen` (no earlier outcome).
  """
  def failure_streaks(%Run{} = run) do
    red =
      from t in TestResult,
        where: t.run_id == ^run.id and t.status in ^@failures,
        distinct: true,
        select: %{suite: t.suite, classname: t.classname, name: t.name}

    case Repo.all(red) do
      [] ->
        %{}

      tests ->
        found =
          run.test_definition_id
          |> outcomes()
          |> in_environment(run.environment_id)
          |> where([run: r], r.id < ^run.id)
          |> join(:inner, [result: t], i in subquery(red),
            on: i.suite == t.suite and i.classname == t.classname and i.name == t.name
          )
          |> streaks()
          |> Repo.all()
          |> Map.new(&{test_of(&1), &1})

        Map.new(tests, &{&1, failure_streak(found[&1])})
    end
  end

  defp failure_streak(nil), do: :first_seen

  defp failure_streak(%{last_pass: last_pass, last_red: last_red, since: since}),
    do: if(passing?(last_pass, last_red), do: :new, else: {:since, since})

  defp passing?(nil, _last_red), do: false
  defp passing?(_last_pass, nil), do: true
  defp passing?(last_pass, last_red), do: last_pass > last_red

  # Per identity of `outcomes`, its current streak: the runs after the latest run
  # of the other colour. `last_pass` and `last_red` tell the colour.
  defp streaks(outcomes) do
    counted = from o in subquery(outcomes), where: o.outcome != "skipped"

    latest =
      from o in counted,
        group_by: [o.suite, o.classname, o.name],
        select: %{
          suite: o.suite,
          classname: o.classname,
          name: o.name,
          last_pass: filter(max(o.run_id), o.outcome == "passed"),
          last_red: filter(max(o.run_id), o.outcome != "passed")
        }

    from o in counted,
      join: l in subquery(latest),
      on: l.suite == o.suite and l.classname == o.classname and l.name == o.name,
      where:
        o.run_id > fragment("LEAST(COALESCE(?, 0), COALESCE(?, 0))", l.last_pass, l.last_red),
      group_by: [o.suite, o.classname, o.name, l.last_pass, l.last_red],
      select: %{
        suite: o.suite,
        classname: o.classname,
        name: o.name,
        last_pass: l.last_pass,
        last_red: l.last_red,
        since: min(o.run_id),
        count: count()
      }
  end

  @doc """
  Compares two final runs of a test definition with JUnit, test by test (see
  `TestFleet.Results.Comparison`).
  """
  def compare(%Run{} = run, %Run{} = baseline),
    do: %{
      Comparison.diff(run_outcomes(run), run_outcomes(baseline))
      | run: run,
        baseline: baseline
    }

  defp run_outcomes(%Run{id: run_id}) do
    from(t in TestResult,
      where: t.run_id == ^run_id,
      group_by: [t.suite, t.classname, t.name],
      select: %{
        suite: t.suite,
        classname: t.classname,
        name: t.name,
        outcome: outcome(t.status),
        failure_message: first_failure_message(t)
      }
    )
    |> Repo.all()
    |> Enum.map(&cast_outcome/1)
  end

  # One row per run and identity, with the run's image digest.
  defp outcomes(test_definition_id) do
    from t in TestResult,
      as: :result,
      join: r in Run,
      as: :run,
      on: r.id == t.run_id,
      where: t.test_definition_id == ^test_definition_id,
      group_by: [r.id, t.suite, t.classname, t.name],
      select: %{
        run_id: r.id,
        image_digest: r.image_digest,
        suite: t.suite,
        classname: t.classname,
        name: t.name,
        outcome: outcome(t.status),
        mixed: mixed(t.status)
      }
  end

  defp for_test(query, %{suite: suite, classname: classname, name: name}) do
    where(
      query,
      [result: t],
      t.suite == ^suite and t.classname == ^classname and t.name == ^name
    )
  end

  defp in_environment(query, environment_id),
    do: where(query, [run: r], r.environment_id == ^environment_id)

  # The latest runs of the test definition in the environment with JUnit, up to
  # and including `up_to` when given.
  defp in_window(query, test_definition_id, environment_id, up_to) do
    window =
      from r in Run,
        where:
          r.test_definition_id == ^test_definition_id and
            r.environment_id == ^environment_id and not is_nil(r.tests_passed),
        order_by: [desc: r.id],
        limit: ^@window,
        select: r.id

    window = if up_to, do: where(window, [r], r.id <= ^up_to), else: window

    where(query, [run: r], r.id in subquery(window))
  end

  defp cast_outcome(%{outcome: outcome} = row),
    do: %{row | outcome: Map.fetch!(@outcomes, outcome)}
end
