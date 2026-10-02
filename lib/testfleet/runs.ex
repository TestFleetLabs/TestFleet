defmodule TestFleet.Runs do
  @moduledoc """
  Runs: every execution of a test definition (main spec sections 7, 8, and 29).

  Manual, scheduled, and API runs are all created `queued` and differ only in
  `trigger`. The dispatcher starts them (Milestone 3, section 5).

  Every change is broadcast with the run's test definition, project, and
  environment preloaded, on `run:<id>` and on `runs`:

      {:run_created, run}
      {:run_updated, run}
      {:run_finished, run}

  Output lines are broadcast on `run:<id>` only, as `{:run_output, lines}`.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Accounts.{APIToken, User}
  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.Storage
  alias TestFleet.Environments.Environment
  alias TestFleet.Execution
  alias TestFleet.Execution.{Request, Result}
  alias TestFleet.Notifications.EvaluateWorker
  alias TestFleet.Projects.Project
  alias TestFleet.Registries
  alias TestFleet.Repo
  alias TestFleet.Results
  alias TestFleet.Runs.{LogLine, Run}
  alias TestFleet.Schedules.Schedule
  alias TestFleet.TestDefinitions.TestDefinition

  @topic "runs"
  @default_limit 50
  @stop_grace_seconds 30
  @max_log_bytes 50 * 1024 * 1024

  ## PubSub

  @doc "Subscribes to changes of all runs."
  def subscribe, do: Phoenix.PubSub.subscribe(TestFleet.PubSub, @topic)

  @doc "Subscribes to changes of one run."
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(TestFleet.PubSub, run_topic(run_id))

  defp run_topic(run_id), do: "run:#{run_id}"

  ## Reading

  @doc "Gets a run with its test definition (and project) and environment."
  def get_run!(id), do: Run |> Repo.get!(id) |> preload()

  @doc "Like `get_run!/1`, but nil when there is no such run."
  def get_run(id) do
    if run = Repo.get(Run, id), do: preload(run)
  end

  @doc """
  Runs, newest first, preloaded like `get_run!/1`.

  Options: `:limit` (default #{@default_limit}), `:project`, `:test_definition`,
  `:statuses`, and `oldest_first: true`.
  """
  def list_runs(opts \\ []) do
    direction = if opts[:oldest_first], do: :asc, else: :desc

    query =
      from r in Run,
        order_by: [{^direction, r.id}],
        limit: ^Keyword.get(opts, :limit, @default_limit)

    opts
    |> Enum.reduce(query, &filter/2)
    |> Repo.all()
    |> preload()
  end

  defp filter({:project, %Project{id: id}}, query) do
    from r in query,
      join: t in assoc(r, :test_definition),
      where: t.project_id == ^id
  end

  defp filter({:test_definition, %TestDefinition{id: id}}, query),
    do: from(r in query, where: r.test_definition_id == ^id)

  defp filter({:statuses, statuses}, query), do: from(r in query, where: r.status in ^statuses)
  defp filter(_option, query), do: query

  @doc "Whether a project, test definition, or environment has runs."
  def has_runs?(%Project{id: id}) do
    Repo.exists?(from r in Run, join: t in assoc(r, :test_definition), where: t.project_id == ^id)
  end

  def has_runs?(%TestDefinition{id: id}),
    do: Repo.exists?(from r in Run, where: r.test_definition_id == ^id)

  def has_runs?(%Environment{id: id}),
    do: Repo.exists?(from r in Run, where: r.environment_id == ^id)

  @doc """
  The dashboard figures (Milestone 3, section 10): `running` (`preparing` +
  `running`), `queued`, and the runs that finished today as `passed`, `failed`, or
  `timeout`. "Today" is the calendar day of `now` in `timezone`.
  """
  def dashboard_stats(timezone, now \\ DateTime.utc_now()) do
    since = start_of_day(now, timezone)

    counts =
      Repo.all(
        from r in Run,
          where:
            r.status in ^[:queued | Run.active_statuses()] or
              (r.status in [:passed, :failed, :timeout] and r.finished_at >= ^since),
          group_by: r.status,
          select: {r.status, count(r.id)}
      )
      |> Map.new()

    %{
      running: Map.get(counts, :preparing, 0) + Map.get(counts, :running, 0),
      queued: Map.get(counts, :queued, 0),
      passed_today: Map.get(counts, :passed, 0),
      failed_today: Map.get(counts, :failed, 0),
      timeouts_today: Map.get(counts, :timeout, 0)
    }
  end

  # Midnight may not exist, or exist twice, on a daylight saving change.
  defp start_of_day(now, timezone) do
    date = now |> DateTime.shift_zone!(timezone) |> DateTime.to_date()

    midnight =
      case DateTime.new(date, ~T[00:00:00], timezone) do
        {:ok, midnight} -> midnight
        {:ambiguous, first, _second} -> first
        {:gap, _before, just_after} -> just_after
      end

    midnight |> DateTime.shift_zone!("Etc/UTC") |> usec()
  end

  ## Creating

  @doc """
  Creates a queued run for "Run now" or the API.

  Options: `:trigger` (`:manual`, the default, or `:api`), `:user` who started it,
  and the `:api_token` it was started with (Milestone 11, section 6).

  The test definition is read again, so a definition disabled in the meantime is
  rejected.
  """
  def create_run(%TestDefinition{id: id}, %Environment{} = environment, opts \\ []) do
    test_definition = Repo.get!(TestDefinition, id)
    trigger = Keyword.get(opts, :trigger, :manual)
    user = opts[:user]
    api_token = opts[:api_token]

    cond do
      !test_definition.enabled ->
        {:error, :test_definition_disabled}

      test_definition.project_id != environment.project_id ->
        {:error, :environment_mismatch}

      true ->
        run =
          Repo.insert!(%Run{
            trigger: trigger,
            status: :queued,
            test_definition_id: test_definition.id,
            environment_id: environment.id,
            triggered_by_user_id: user && user.id,
            api_token_id: api_token && api_token.id,
            image: test_definition.image,
            command: test_definition.command,
            queued_at: DateTime.utc_now()
          })

        run = preload(run)
        broadcast(run, :run_created)
        {:ok, run}
    end
  end

  @doc """
  Creates the queued run of a schedule's slot, unless the overlap policy or a
  disabled test definition says to skip it (Milestone 5, sections 5 and 6):

      {:ok, run} | {:ok, :exists} | {:skipped, :overlap | :test_definition_disabled}

  Meant to run inside the schedule tick's transaction, with the schedule locked; it
  does not broadcast. The caller broadcasts with `broadcast_created/1` after the commit.
  """
  def create_scheduled(
        %Schedule{} = schedule,
        %DateTime{} = scheduled_for,
        now \\ DateTime.utc_now()
      ) do
    test_definition = Repo.get!(TestDefinition, schedule.test_definition_id)

    cond do
      !test_definition.enabled ->
        {:skipped, :test_definition_disabled}

      overlap?(schedule) ->
        {:skipped, :overlap}

      true ->
        run = %Run{
          trigger: :schedule,
          status: :queued,
          schedule_id: schedule.id,
          scheduled_for: usec(scheduled_for),
          test_definition_id: test_definition.id,
          environment_id: schedule.environment_id,
          image: test_definition.image,
          command: test_definition.command,
          queued_at: usec(now)
        }

        # The unique index on (schedule_id, scheduled_for) guards against a slot
        # created twice, whatever the cause.
        case Repo.insert(run,
               on_conflict: :nothing,
               conflict_target: [:schedule_id, :scheduled_for]
             ) do
          {:ok, %Run{id: nil}} -> {:ok, :exists}
          {:ok, run} -> {:ok, preload(run)}
        end
    end
  end

  # A schedule's own unfinished runs; manual runs do not count.
  defp overlap?(%Schedule{overlap_policy: :allow}), do: false

  defp overlap?(%Schedule{id: id, overlap_policy: policy}) do
    statuses =
      Repo.all(
        from r in Run,
          where: r.schedule_id == ^id and r.status in ^[:queued | Run.active_statuses()],
          select: r.status
      )

    case policy do
      :skip -> statuses != []
      # At most one run waits.
      :queue -> :queued in statuses
    end
  end

  @doc "Announces a run created without broadcasting, e.g. by `create_scheduled/3` after its commit."
  def broadcast_created(%Run{} = run), do: broadcast(run, :run_created)

  ## Cancelling

  @doc """
  Cancels a run. Idempotent.

  A queued run is cancelled right away. An active run is cancelled by its
  execution process, which records the final status.
  """
  def cancel_run(%Run{id: id}) do
    case transition(id, [:queued], status: :cancelled, finished_at: DateTime.utc_now()) do
      {:ok, _run} ->
        :ok

      :error ->
        run = Repo.get!(Run, id)

        if run.status in Run.active_statuses() do
          # Persisted first: if no process owns the run right now, the reconciler
          # finishes the cancel (Milestone 7, section 5).
          if is_nil(run.cancel_requested_at) do
            transition(id, Run.active_statuses(), cancel_requested_at: DateTime.utc_now())
          end

          Execution.cancel(id)
        end

        :ok
    end
  end

  @doc """
  Finalizes an active run as `cancelled` without an execution result: its cancel
  was requested and it has no container (Milestone 7, reconciler rule 4).
  """
  def mark_cancelled(run_id) do
    transition(run_id, Run.active_statuses(),
      status: :cancelled,
      finished_at: DateTime.utc_now()
    )
  end

  ## Dispatching

  @doc """
  Queued runs, oldest first, with their environment (for its limit) and schedule
  (for its overlap policy).
  """
  def list_queued do
    Repo.all(
      from r in Run,
        where: r.status == :queued,
        order_by: [asc: r.id],
        preload: [:environment, :schedule]
    )
  end

  @doc "The ids of schedules that have a `preparing` or `running` run."
  def active_schedule_ids do
    Repo.all(
      from r in Run,
        where: r.status in ^Run.active_statuses() and not is_nil(r.schedule_id),
        distinct: true,
        select: r.schedule_id
    )
    |> MapSet.new()
  end

  @doc """
  Runs holding a slot under the concurrency limits (`preparing`, `running`):
  `{total, %{environment_id => count}}`.
  """
  def active_counts do
    by_environment =
      Repo.all(
        from r in Run,
          where: r.status in ^Run.active_statuses(),
          group_by: r.environment_id,
          select: {r.environment_id, count(r.id)}
      )
      |> Map.new()

    {by_environment |> Map.values() |> Enum.sum(), by_environment}
  end

  @doc "Runs that are `preparing` or `running`, oldest first."
  def list_active do
    Repo.all(from r in Run, where: r.status in ^Run.active_statuses(), order_by: [asc: r.id])
  end

  @doc "The ids among `ids` that belong to runs in this database."
  def existing_run_ids(ids) do
    Repo.all(from r in Run, where: r.id in ^ids, select: r.id)
  end

  @doc """
  The latest run of `run`'s series (its test definition in its environment) that
  was created before it and ended with one of `statuses`, or `nil`.
  """
  def previous_run(%Run{} = run, statuses) do
    Repo.one(
      from r in Run,
        where:
          r.test_definition_id == ^run.test_definition_id and
            r.environment_id == ^run.environment_id and r.id < ^run.id and
            r.status in ^statuses,
        order_by: [desc: r.id],
        limit: 1
    )
  end

  @doc "The ids among `ids` that belong to finished runs."
  def final_run_ids(ids) do
    Repo.all(
      from r in Run, where: r.id in ^ids and r.status in ^Run.final_statuses(), select: r.id
    )
  end

  @doc "Admits a queued run: `queued → preparing`. `:error` if it is no longer queued."
  def mark_preparing(%Run{id: id}), do: transition(id, [:queued], status: :preparing)

  @doc """
  Builds the execution request (Milestone 3, section 6). It holds decrypted
  variables and registry credentials; `Request` keeps them out of `inspect`.
  """
  def build_request(%Run{} = run) do
    run = Repo.preload(run, [:test_definition, environment: :variables], force: true)
    %{test_definition: test_definition, environment: environment} = run

    registry_auth =
      case Registries.get_registry_for_image(run.image) do
        nil -> nil
        registry -> %{username: registry.username, password: registry.password}
      end

    Request.new(
      run_id: run.id,
      project_id: test_definition.project_id,
      instance_id: TestFleet.Instance.id(),
      environment_name: environment.slug,
      image: run.image,
      command: run.command,
      environment: Map.new(environment.variables, &{&1.key, &1.value}),
      secret_keys: for(%{secret: true, key: key} <- environment.variables, do: key),
      registry_auth: registry_auth,
      timeout_seconds: test_definition.timeout_seconds,
      cpu_limit: test_definition.cpu_limit,
      memory_limit: test_definition.memory_limit,
      shm_size: test_definition.shm_size_bytes,
      pull_policy: :auto,
      pull_timeout_ms: Execution.pull_timeout(),
      stop_grace_seconds: @stop_grace_seconds,
      artifact_path: Storage.run_dir(run.id),
      max_artifact_bytes: Artifacts.max_bytes()
    )
  end

  ## Recording execution (see `TestFleet.Runs.Recorder`)

  @doc "Records facts of an active run, e.g. `image_digest` or `container_id`."
  def record(run_id, changes) do
    transition(run_id, Run.active_statuses(), changes)
  end

  @doc "`preparing → running`, with the container's start time."
  def mark_running(run_id, %DateTime{} = started_at) do
    transition(run_id, [:preparing], status: :running, started_at: started_at)
  end

  @doc """
  Records the final status of a run from the execution result, with its test
  counts, warnings, artifacts, and test results, in one transaction (Milestone 6,
  section 6). A run is never visible as finished without its results; a repeated
  finish changes and inserts nothing.
  """
  def finish(run_id, %Result{} = result) do
    changes =
      [
        status: result.status,
        finished_at: result.finished_at,
        exit_code: result.exit_code,
        oom_killed: result.oom_killed,
        error_message: result.error_message,
        warnings: result.warnings
      ] ++
        Keyword.new(Results.counts(result.test_results)) ++
        for {field, value} <- [
              image_digest: result.image_digest,
              container_id: result.container_id,
              started_at: result.started_at
            ],
            value != nil,
            do: {field, value}

    transaction =
      Repo.transaction(fn ->
        case update_status(run_id, [:queued | Run.active_statuses()], changes) do
          {:ok, run} ->
            Artifacts.insert_all(run, result.artifacts)
            Results.insert_all(run, result.test_results)
            run

          :error ->
            Repo.rollback(:not_active)
        end
      end)

    case transaction do
      {:ok, run} -> {:ok, broadcast_transition(run)}
      {:error, :not_active} -> :error
    end
  end

  @doc """
  Stores a batch of (already masked) output lines and broadcasts it as
  `{:run_output, lines}` on `run:<id>` (Milestone 4, section 6).

  Lines are stored up to the log limit (`:max_log_bytes`, default from
  `config :testfleet, TestFleet.Runs`). The first line that does not fit sets
  `log_truncated`; from then on lines are only broadcast. Lines already stored,
  e.g. read again after a reattach, are skipped.
  """
  def append_log(run_id, lines, opts \\ [])
  def append_log(_run_id, [], _opts), do: :ok

  def append_log(run_id, lines, opts) do
    max_bytes = Keyword.get_lazy(opts, :max_log_bytes, &max_log_bytes/0)
    lines = Enum.map(lines, &sanitize_line/1)

    {:ok, cut?} =
      Repo.transaction(fn ->
        %{log_bytes: log_bytes, log_truncated: truncated} =
          Repo.one!(
            from r in Run,
              where: r.id == ^run_id,
              select: %{log_bytes: r.log_bytes, log_truncated: r.log_truncated},
              lock: "FOR UPDATE"
          )

        {fitting, cut?} =
          if truncated, do: {[], false}, else: take_fitting(lines, max_bytes - log_bytes)

        {_count, inserted} =
          Repo.insert_all(LogLine, Enum.map(fitting, &Map.put(&1, :run_id, run_id)),
            on_conflict: :nothing,
            returning: [:content]
          )

        last_sequence = List.last(lines).sequence
        # The newest, not the last line's: stdout and stderr lines interleave, and a
        # reattach skips every line not newer than this (Milestone 4, section 7).
        newest_timestamp =
          lines |> Enum.map(& &1.timestamp) |> Enum.reject(&is_nil/1) |> Enum.max(fn -> nil end)

        Repo.update_all(
          from(r in Run,
            where: r.id == ^run_id,
            update: [
              set: [
                last_log_sequence:
                  fragment("GREATEST(?, ?)", r.last_log_sequence, ^last_sequence),
                last_log_timestamp:
                  fragment("GREATEST(?, ?::bigint)", r.last_log_timestamp, ^newest_timestamp),
                log_truncated: ^(truncated or cut?)
              ],
              inc: [log_bytes: ^Enum.sum_by(inserted, &byte_size(&1.content))]
            ]
          ),
          []
        )

        cut?
      end)

    Phoenix.PubSub.broadcast(TestFleet.PubSub, run_topic(run_id), {:run_output, lines})

    # Once per run: the run page shows that later output is not stored.
    if cut?, do: broadcast(get_run!(run_id), :run_updated)

    :ok
  end

  # PostgreSQL text cannot hold NUL bytes.
  defp sanitize_line(line) do
    %{
      sequence: line.sequence,
      stream: line.stream,
      content: String.replace(line.content, <<0>>, "�"),
      timestamp: line.timestamp
    }
  end

  defp take_fitting(lines, remaining), do: take_fitting(lines, remaining, [])

  defp take_fitting([], _remaining, acc), do: {Enum.reverse(acc), false}

  defp take_fitting([line | rest], remaining, acc) do
    size = byte_size(line.content)

    if size <= remaining,
      do: take_fitting(rest, remaining - size, [line | acc]),
      else: {Enum.reverse(acc), true}
  end

  @doc "The stored log size per run (`config :testfleet, TestFleet.Runs, max_log_bytes: ...`)."
  def max_log_bytes,
    do: Application.get_env(:testfleet, __MODULE__, [])[:max_log_bytes] || @max_log_bytes

  @doc """
  Reduces over a run's stored log in order, in chunks of up to 1,000 lines, without
  loading it into memory: `fun.(lines, acc)` returns the new acc.
  """
  def reduce_log(%Run{id: id}, acc, fun) do
    query = from l in LogLine, where: l.run_id == ^id, order_by: l.sequence

    {:ok, acc} =
      Repo.transaction(
        fn ->
          query
          |> Repo.stream(max_rows: 1_000)
          |> Stream.chunk_every(1_000)
          |> Enum.reduce(acc, fun)
        end,
        timeout: :infinity
      )

    acc
  end

  @doc "The last `limit` stored lines of a run, in order."
  def list_log_tail(%Run{id: id}, limit) do
    Repo.all(
      from l in LogLine,
        where: l.run_id == ^id,
        order_by: [desc: l.sequence],
        limit: ^limit
    )
    |> Enum.reverse()
  end

  @doc """
  Pins or unpins a run. A pinned run is exempt from retention (Milestone 6,
  section 8); unpinning an old run lets the next cleanup expire it.
  """
  def set_pinned(%Run{id: id}, pinned) when is_boolean(pinned) do
    {1, _} =
      Repo.update_all(from(r in Run, where: r.id == ^id),
        set: [pinned: pinned, updated_at: DateTime.utc_now()]
      )

    {:ok, broadcast_updated(id)}
  end

  @doc "Broadcasts `{:run_updated, run}` with the run as stored, e.g. after retention."
  def broadcast_updated(run_id) do
    run = get_run!(run_id)
    broadcast(run, :run_updated)
    run
  end

  @doc "Finalizes a run as `error` without an execution result, e.g. when it cannot start."
  def fail(run_id, message) do
    transition(run_id, [:queued | Run.active_statuses()],
      status: :error,
      error_message: message,
      finished_at: DateTime.utc_now()
    )
  end

  ## Transitions

  # Updates the run only while its status is one of `from`, so a late or repeated
  # event cannot reopen a finished run.
  defp transition(id, from, changes) do
    transaction =
      Repo.transaction(fn ->
        case update_status(id, from, changes) do
          {:ok, run} -> run
          :error -> Repo.rollback(:not_in_from)
        end
      end)

    case transaction do
      {:ok, run} -> {:ok, broadcast_transition(run)}
      {:error, :not_in_from} -> :error
    end
  end

  # Every status change goes through here. A run that becomes final gets its
  # notification evaluation in the same transaction (Milestone 8, section 6), so a
  # final run is always evaluated, even if TestFleet stops right after the commit.
  # Callers run it inside a transaction.
  defp update_status(id, from, changes) do
    with {:ok, run} <- update_status_row(id, from, changes) do
      if Run.final?(run), do: Oban.insert!(EvaluateWorker.new(%{run_id: run.id}))
      {:ok, run}
    end
  end

  defp update_status_row(id, from, changes) do
    changes =
      changes
      |> Keyword.put(:updated_at, DateTime.utc_now())
      |> Enum.map(fn
        {field, %DateTime{} = value} -> {field, usec(value)}
        change -> change
      end)

    query = from r in Run, where: r.id == ^id and r.status in ^from, select: r

    case Repo.update_all(query, set: changes) do
      {1, [run]} -> {:ok, run}
      {0, _} -> :error
    end
  end

  defp broadcast_transition(run) do
    run = preload(run)
    broadcast(run, if(Run.final?(run), do: :run_finished, else: :run_updated))
    run
  end

  defp broadcast(%Run{} = run, event) do
    message = {event, run}
    Phoenix.PubSub.broadcast(TestFleet.PubSub, run_topic(run.id), message)
    Phoenix.PubSub.broadcast(TestFleet.PubSub, @topic, message)
  end

  # The columns are utc_datetime_usec; Docker's StartedAt may come with less precision.
  defp usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  # Runs are broadcast: of the user and the token, only what the UI shows.
  defp preload(run_or_runs) do
    Repo.preload(run_or_runs, [
      :environment,
      test_definition: :project,
      triggered_by_user: from(u in User, select: struct(u, [:id, :email])),
      api_token: from(t in APIToken, select: struct(t, [:id, :name]))
    ])
  end
end
