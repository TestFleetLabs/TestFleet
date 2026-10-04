defmodule TestFleet.Artifacts do
  @moduledoc """
  Files a suite leaves in `/TestFleet/artifacts`.

  `RunExecution` collects them into `TestFleet.Artifacts.Storage`; `Runs.finish/2`
  stores their rows with the run's final status.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Artifacts.{Artifact, Storage}
  alias TestFleet.Repo
  alias TestFleet.Runs.Run

  @default_max_bytes 500 * 1024 * 1024
  @chunk_size 1_000

  @doc "The most a run may keep, measured on the archive (`ARTIFACT_LIMIT_MB`)."
  def max_bytes do
    Application.get_env(:testfleet, __MODULE__, [])[:max_bytes] || @default_max_bytes
  end

  @doc "A run's artifacts, by name."
  def list_artifacts(%Run{id: run_id}) do
    Repo.all(from a in Artifact, where: a.run_id == ^run_id, order_by: a.name)
  end

  @doc """
  The artifact of a run with exactly this name, or `nil`. Downloads look names up
  here and never build a file path from a request.
  """
  def get_artifact(run_id, name) when is_binary(name) do
    with {run_id, ""} <- Integer.parse(to_string(run_id)) do
      Repo.get_by(Artifact, run_id: run_id, name: name)
    else
      _ -> nil
    end
  end

  @doc "The file of an artifact."
  def path(%Artifact{storage_key: key}), do: Storage.path(key)

  @doc """
  Inserts the rows of collected artifacts (`%{path, size_bytes}`, as in
  `TestFleet.Execution.Result`). Names already stored are skipped. Called by
  `Runs.finish/2` inside its transaction.
  """
  def insert_all(%Run{id: run_id}, artifacts) do
    now = DateTime.utc_now()

    artifacts
    |> Enum.map(fn %{path: name, size_bytes: size} ->
      %{
        run_id: run_id,
        name: name,
        content_type: MIME.from_path(name),
        size_bytes: size,
        storage_backend: Storage.backend(),
        storage_key: Storage.key(run_id, name),
        inserted_at: now
      }
    end)
    |> Enum.chunk_every(@chunk_size)
    |> Enum.each(&Repo.insert_all(Artifact, &1, on_conflict: :nothing))
  end
end
