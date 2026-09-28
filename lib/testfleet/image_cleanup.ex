defmodule TestFleet.ImageCleanup do
  @moduledoc """
  Removes images TestFleet pulled and no longer needs, by digest, never with a
  host-wide prune (main spec section 39, Milestone 7 section 8).

      config :testfleet, TestFleet.Execution,
        image_retention_days: 7   # IMAGE_RETENTION_DAYS

  Candidates are the `(image, image_digest)` pairs of runs. Kept are pairs used by a
  run within `image_retention_days`, and the latest digest of every image an enabled test
  definition references, whatever its age: it is what the next run starts from.
  Every other pair is removed as `<name>@<digest>`, if Docker still has it.
  """

  import Ecto.Query, warn: false

  require Logger

  alias TestFleet.Execution
  alias TestFleet.Repo
  alias TestFleet.Runs.Run
  alias TestFleet.TestDefinitions.TestDefinition

  @doc "Days an unused digest is kept (`IMAGE_RETENTION_DAYS`, default 7)."
  def retention_days,
    do: Application.get_env(:testfleet, Execution, [])[:image_retention_days] || 7

  @doc """
  The digest references due for removal at `now`, from the database alone: every
  one ever used, so an image Docker already removed is still listed.
  """
  def due(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -retention_days(), :day)
    kept = MapSet.new(latest_of_enabled())

    Repo.all(
      from r in Run,
        where: not is_nil(r.image_digest),
        group_by: [r.image, r.image_digest],
        having: max(r.inserted_at) < ^cutoff,
        select: {r.image, r.image_digest}
    )
    |> Enum.reject(&MapSet.member?(kept, &1))
    |> Enum.map(fn {image, digest} -> Execution.digest_reference(image, digest) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # The digest of the newest run of each image an enabled test definition uses.
  defp latest_of_enabled do
    Repo.all(
      from r in Run,
        join: t in TestDefinition,
        on: t.image == r.image and t.enabled,
        where: not is_nil(r.image_digest),
        distinct: r.image,
        order_by: [asc: r.image, desc: r.id],
        select: {r.image, r.image_digest}
    )
  end

  @doc """
  Removes what is due and still present in Docker. Returns how many references
  were removed, and how many Docker refused because a container or another tag
  still uses them (tried again next time). Without Docker, nothing is removed.
  """
  def run(now \\ DateTime.utc_now()) do
    with {:ok, local} <- Execution.local_digest_references() do
      now
      |> due()
      |> Enum.filter(&MapSet.member?(local, &1))
      |> Enum.reduce(%{removed: 0, in_use: 0}, fn reference, counts ->
        case Execution.remove_image(reference) do
          :ok ->
            Logger.info("removed image #{reference}")
            Map.update!(counts, :removed, &(&1 + 1))

          {:error, %{status: 409}} ->
            Map.update!(counts, :in_use, &(&1 + 1))

          {:error, error} ->
            Logger.warning("cannot remove image #{reference}: #{error.message}")
            counts
        end
      end)
      |> then(&{:ok, &1})
    end
  end
end
