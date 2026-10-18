defmodule TestFleet.Statistics do
  @moduledoc """
  Figures for the admins' statistics page: what an organization has configured,
  how many runs it made, and how much storage its runs hold; and for the whole
  installation, the database's tables and the Docker images TestFleet pulled.

  Everything is read when asked for, nothing is stored. Row counts of the
  installation's tables are PostgreSQL's estimates (`n_live_tup`), so that the page
  does not count a `run_logs` table of millions of rows.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Accounts.{Scope, User}
  alias TestFleet.Artifacts.Artifact
  alias TestFleet.Environments.Environment
  alias TestFleet.Execution
  alias TestFleet.Organizations.{Membership, Organization}
  alias TestFleet.Projects.Project
  alias TestFleet.Repo
  alias TestFleet.Results.TestResult
  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.Schedule
  alias TestFleet.TestDefinitions.TestDefinition

  @largest_suites 5
  @tables 10

  @doc """
  The organization's figures:

    * `:configuration` - projects, test definitions, environments, schedules
      (`{total, enabled}` where they can be disabled), and members
    * `:runs` - `total`, `last_30_days`, `pinned`, and `by_status`
    * `:storage` - artifacts (`bytes`, `files`, `runs`) and logs (`bytes`, `runs`)
      still stored, the runs whose artifacts expired, and the test results
    * `:largest_suites` - the test definitions holding the most artifact bytes
  """
  def organization(%Scope{organization: %Organization{id: org_id}}, now \\ DateTime.utc_now()) do
    %{
      configuration: configuration(org_id),
      runs: runs(org_id, now),
      storage: storage(org_id),
      largest_suites: largest_suites(org_id)
    }
  end

  defp configuration(org_id) do
    test_definitions =
      Repo.one(
        from t in TestDefinition,
          join: p in assoc(t, :project),
          where: p.organization_id == ^org_id,
          select: {count(t.id), filter(count(t.id), t.enabled)}
      )

    schedules =
      Repo.one(
        from s in Schedule,
          join: t in assoc(s, :test_definition),
          join: p in assoc(t, :project),
          where: p.organization_id == ^org_id,
          select: {count(s.id), filter(count(s.id), s.enabled)}
      )

    %{
      projects: Repo.aggregate(from(p in Project, where: p.organization_id == ^org_id), :count),
      test_definitions: test_definitions,
      environments:
        Repo.aggregate(
          from(e in Environment,
            join: p in assoc(e, :project),
            where: p.organization_id == ^org_id
          ),
          :count
        ),
      schedules: schedules,
      members: Repo.aggregate(from(m in Membership, where: m.organization_id == ^org_id), :count)
    }
  end

  defp runs(org_id, now) do
    since = DateTime.add(now, -30, :day)

    by_status =
      Repo.all(
        from r in Run,
          where: r.organization_id == ^org_id,
          group_by: r.status,
          select: {r.status, count(r.id)}
      )
      |> Map.new()

    Repo.one(
      from r in Run,
        where: r.organization_id == ^org_id,
        select: %{
          total: count(r.id),
          last_30_days: filter(count(r.id), r.inserted_at >= ^since),
          pinned: filter(count(r.id), r.pinned)
        }
    )
    |> Map.put(:by_status, by_status)
  end

  defp storage(org_id) do
    artifacts =
      Repo.one(
        from a in Artifact,
          join: r in assoc(a, :run),
          where: r.organization_id == ^org_id,
          select: %{
            bytes: type(coalesce(sum(a.size_bytes), 0), :integer),
            files: count(a.id),
            runs: count(r.id, :distinct)
          }
      )

    runs =
      Repo.one(
        from r in Run,
          where: r.organization_id == ^org_id,
          select: %{
            log_bytes:
              type(
                coalesce(filter(sum(r.log_bytes), is_nil(r.logs_expired_at)), 0),
                :integer
              ),
            log_runs: filter(count(r.id), is_nil(r.logs_expired_at) and r.log_bytes > 0),
            artifacts_expired: filter(count(r.id), not is_nil(r.artifacts_expired_at))
          }
      )

    test_results =
      Repo.aggregate(
        from(t in TestResult, join: r in assoc(t, :run), where: r.organization_id == ^org_id),
        :count
      )

    %{
      artifacts: artifacts,
      logs: %{bytes: runs.log_bytes, runs: runs.log_runs},
      artifacts_expired: runs.artifacts_expired,
      test_results: test_results
    }
  end

  defp largest_suites(org_id) do
    Repo.all(
      from a in Artifact,
        join: r in assoc(a, :run),
        join: t in assoc(r, :test_definition),
        join: p in assoc(t, :project),
        where: r.organization_id == ^org_id,
        group_by: [t.id, p.id],
        order_by: [desc: sum(a.size_bytes), asc: t.id],
        limit: @largest_suites,
        select: %{
          id: t.id,
          name: t.name,
          artifact_retention_days: t.artifact_retention_days,
          project_slug: p.slug,
          project_name: p.name,
          bytes: type(sum(a.size_bytes), :integer),
          runs: count(r.id, :distinct)
        }
    )
  end

  @doc """
  The installation's figures, across all organizations: `organizations`, active
  `users`, `database_bytes`, the largest `tables` (`name`, estimated `rows`,
  `bytes` with indexes), and the artifacts and logs stored.
  """
  def installation do
    %{rows: [[database_bytes]]} =
      Repo.query!("SELECT pg_database_size(current_database())")

    %{rows: tables} =
      Repo.query!(
        """
        SELECT relname, n_live_tup, pg_total_relation_size(relid)
        FROM pg_stat_user_tables
        WHERE schemaname = current_schema()
        ORDER BY pg_total_relation_size(relid) DESC, relname
        LIMIT $1
        """,
        [@tables]
      )

    artifacts =
      Repo.one(
        from a in Artifact,
          select: %{bytes: type(coalesce(sum(a.size_bytes), 0), :integer), files: count(a.id)}
      )

    log_bytes =
      Repo.one(
        from r in Run,
          where: is_nil(r.logs_expired_at),
          select: type(coalesce(sum(r.log_bytes), 0), :integer)
      )

    %{
      organizations: Repo.aggregate(Organization, :count),
      users: Repo.aggregate(from(u in User, where: is_nil(u.deactivated_at)), :count),
      database_bytes: database_bytes,
      tables:
        Enum.map(tables, fn [name, rows, bytes] -> %{name: name, rows: rows, bytes: bytes} end),
      artifacts: artifacts,
      log_bytes: log_bytes
    }
  end

  @doc """
  The Docker images on the host, and which of them TestFleet's runs pulled:
  `{:ok, %{count, bytes, host_count, host_bytes}}`, or Docker's error.
  """
  def images do
    with {:ok, images} <- Execution.local_images() do
      {:ok, image_usage(images, recorded_references())}
    end
  end

  @doc """
  Sums `images` (as `Execution.local_images/0` returns them), and those of them
  with one of the digest `references` runs recorded.
  """
  def image_usage(images, references) do
    ours =
      Enum.filter(images, fn image ->
        Enum.any?(image.digest_references, &MapSet.member?(references, &1))
      end)

    %{
      count: length(ours),
      bytes: ours |> Enum.map(& &1.size) |> Enum.sum(),
      host_count: length(images),
      host_bytes: images |> Enum.map(& &1.size) |> Enum.sum()
    }
  end

  # Every `name@digest` a run ever used, as image cleanup knows them.
  defp recorded_references do
    Repo.all(
      from r in Run,
        where: not is_nil(r.image_digest),
        distinct: true,
        select: {r.image, r.image_digest}
    )
    |> Enum.map(fn {image, digest} -> Execution.digest_reference(image, digest) end)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end
end
