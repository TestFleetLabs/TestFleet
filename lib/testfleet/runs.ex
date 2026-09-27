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
  """

  import Ecto.Query, warn: false

  alias TestFleet.Environments.Environment
  alias TestFleet.Execution
  alias TestFleet.Execution.{Request, Result}
  alias TestFleet.Projects.Project
  alias TestFleet.Registries
  alias TestFleet.Repo
  alias TestFleet.Runs.Run
  alias TestFleet.TestDefinitions.TestDefinition

  @topic "runs"
  @default_limit 50
  @stop_grace_seconds 30

  ## PubSub

  @doc "Subscribes to changes of all runs."
  def subscribe, do: Phoenix.PubSub.subscribe(TestFleet.PubSub, @topic)

  @doc "Subscribes to changes of one run."
  def subscribe(run_id), do: Phoenix.PubSub.subscribe(TestFleet.PubSub, run_topic(run_id))

  defp run_topic(run_id), do: "run:#{run_id}"

  ## Reading

  @doc "Gets a run with its test definition (and project) and environment."
  def get_run!(id), do: Run |> Repo.get!(id) |> preload()

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
  Creates a queued run for "Run now".

  The test definition is read again, so a definition disabled in the meantime is
  rejected.
  """
  def create_manual_run(%TestDefinition{id: id}, %Environment{} = environment) do
    test_definition = Repo.get!(TestDefinition, id)

    cond do
      !test_definition.enabled ->
        {:error, :test_definition_disabled}

      test_definition.project_id != environment.project_id ->
        {:error, :environment_mismatch}

      true ->
        run =
          Repo.insert!(%Run{
            trigger: :manual,
            status: :queued,
            test_definition_id: test_definition.id,
            environment_id: environment.id,
            image: test_definition.image,
            command: test_definition.command,
            queued_at: DateTime.utc_now()
          })

        run = preload(run)
        broadcast(run, :run_created)
        {:ok, run}
    end
  end

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
        if Repo.get!(Run, id).status in Run.active_statuses(), do: Execution.cancel(id)
        :ok
    end
  end

  ## Dispatching

  @doc "Queued runs, oldest first, with their environment (for its limit)."
  def list_queued do
    Repo.all(
      from r in Run,
        where: r.status == :queued,
        order_by: [asc: r.id],
        preload: :environment
    )
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
      environment_name: environment.slug,
      image: run.image,
      command: run.command,
      environment: Map.new(environment.variables, &{&1.key, &1.value}),
      secret_values: for(%{secret: true, value: value} <- environment.variables, do: value),
      registry_auth: registry_auth,
      timeout_seconds: test_definition.timeout_seconds,
      cpu_limit: test_definition.cpu_limit,
      memory_limit: test_definition.memory_limit,
      shm_size: test_definition.shm_size_bytes,
      pull_policy: :auto,
      stop_grace_seconds: @stop_grace_seconds,
      artifact_path: nil
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

  @doc "Records the final status of a run from the execution result."
  def finish(run_id, %Result{} = result) do
    changes =
      [
        status: result.status,
        finished_at: result.finished_at,
        exit_code: result.exit_code,
        oom_killed: result.oom_killed,
        error_message: result.error_message
      ] ++
        for {field, value} <- [
              image_digest: result.image_digest,
              container_id: result.container_id,
              started_at: result.started_at
            ],
            value != nil,
            do: {field, value}

    transition(run_id, [:queued | Run.active_statuses()], changes)
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
    changes =
      changes
      |> Keyword.put(:updated_at, DateTime.utc_now())
      |> Enum.map(fn
        {field, %DateTime{} = value} -> {field, usec(value)}
        change -> change
      end)

    query = from r in Run, where: r.id == ^id and r.status in ^from, select: r

    case Repo.update_all(query, set: changes) do
      {1, [run]} ->
        run = preload(run)
        broadcast(run, if(Run.final?(run), do: :run_finished, else: :run_updated))
        {:ok, run}

      {0, _} ->
        :error
    end
  end

  defp broadcast(%Run{} = run, event) do
    message = {event, run}
    Phoenix.PubSub.broadcast(TestFleet.PubSub, run_topic(run.id), message)
    Phoenix.PubSub.broadcast(TestFleet.PubSub, @topic, message)
  end

  # The columns are utc_datetime_usec; Docker's StartedAt may come with less precision.
  defp usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp preload(run_or_runs),
    do: Repo.preload(run_or_runs, [:environment, test_definition: :project])
end
