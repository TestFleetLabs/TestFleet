defmodule TestFleet.Artifacts.Storage do
  @moduledoc """
  Where artifact files live. The only
  module that turns a run or a storage key into a file path.

  One backend so far, the local filesystem: a run's files are under
  `<root>/<run_id>/`, and a storage key is `<run_id>/<name>`. Object storage adds a
  backend here and an upload step after collection.
  """

  @backend "local"

  def backend, do: @backend

  @doc "The configured root directory, expanded."
  def root do
    :testfleet
    |> Application.get_env(TestFleet.Artifacts, [])
    |> Keyword.get(:root, "tmp/artifacts")
    |> Path.expand()
  end

  @doc "The directory of one run's artifacts."
  def run_dir(run_id), do: Path.join(root(), to_string(run_id))

  @doc "The storage key of a run's artifact."
  def key(run_id, name), do: "#{run_id}/#{name}"

  @doc "The file of a storage key."
  def path(key), do: Path.join(root(), key)
end
