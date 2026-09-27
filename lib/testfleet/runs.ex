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
  alias TestFleet.Projects.Project
  alias TestFleet.Repo
  alias TestFleet.Runs.Run
  alias TestFleet.TestDefinitions.TestDefinition

  @topic "runs"
  @default_limit 50

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
  `:statuses`.
  """
  def list_runs(opts \\ []) do
    query =
      from r in Run,
        order_by: [desc: r.id],
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

  ## Transitions

  # Updates the run only while its status is one of `from`, so a late or repeated
  # event cannot reopen a finished run.
  defp transition(id, from, changes) do
    changes = Keyword.put(changes, :updated_at, DateTime.utc_now())

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

  defp preload(run_or_runs),
    do: Repo.preload(run_or_runs, [:environment, test_definition: :project])
end
