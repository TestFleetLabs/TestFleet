defmodule TestFleet.Artifacts.Orphans do
  @moduledoc """
  Deletes files under the artifacts root that no run accounts for:

    * `<run_id>/` directories of runs that are not in this database
    * `<run_id>.tar` and `<run_id>.extract` leftovers of an interrupted collection,
      unless the run is still active: it may be collecting right now

  Only names made of a run id are considered; anything else in the root is left
  alone. The root belongs to one database (dev and test use different roots), so no
  instance check is needed.
  """

  require Logger

  alias TestFleet.Artifacts.Storage
  alias TestFleet.Runs

  # Longer digit strings are no bigint, so no run id.
  @entry ~r/\A(\d{1,18})(\.tar|\.extract)?\z/

  @doc "Deletes the orphans under `root`. Returns the names deleted."
  def run(root \\ Storage.root()) do
    entries =
      case File.ls(root) do
        {:ok, names} -> for name <- names, entry <- List.wrap(parse(name)), do: entry
        {:error, _} -> []
      end

    ids = entries |> Enum.map(& &1.run_id) |> Enum.uniq()
    existing = MapSet.new(Runs.existing_run_ids(ids))
    final = MapSet.new(Runs.final_run_ids(ids))

    for entry <- entries, orphan?(entry, existing, final) do
      File.rm_rf!(Path.join(root, entry.name))
      Logger.info("deleted orphaned artifact files #{entry.name}")
      entry.name
    end
  end

  defp parse(name) do
    case Regex.run(@entry, name) do
      [_, id] -> %{name: name, run_id: String.to_integer(id), leftover: false}
      [_, id, _suffix] -> %{name: name, run_id: String.to_integer(id), leftover: true}
      nil -> nil
    end
  end

  defp orphan?(%{leftover: false, run_id: id}, existing, _final),
    do: not MapSet.member?(existing, id)

  # Queued and active runs are left alone: a leftover of a finished or unknown run
  # can only be from an interrupted collection.
  defp orphan?(%{leftover: true, run_id: id}, existing, final),
    do: not MapSet.member?(existing, id) or MapSet.member?(final, id)
end
