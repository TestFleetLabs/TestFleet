defmodule TestFleet.Execution.Docker.ImageRef do
  @moduledoc """
  Parses image references the way Docker does.

  The first path segment is a registry host only if it contains `.` or `:`, or is
  `localhost`. Everything else lives on Docker Hub, with single-segment names under
  `library/`.
  """

  @docker_hub "docker.io"

  defstruct [:host, :repository, :tag, :digest]

  @type t :: %__MODULE__{
          host: String.t(),
          repository: String.t(),
          tag: String.t() | nil,
          digest: String.t() | nil
        }

  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_reference}
  def parse(reference) when is_binary(reference) do
    {name, digest} =
      case String.split(reference, "@", parts: 2) do
        [name, digest] -> {name, digest}
        [name] -> {name, nil}
      end

    {name, tag} = split_tag(name)
    {host, repository} = split_host(name)

    if repository == "" or String.ends_with?(repository, "/") or digest == "" or tag == "" do
      {:error, :invalid_reference}
    else
      {:ok,
       %__MODULE__{
         host: host,
         repository: repository,
         tag: if(tag == nil and digest == nil, do: "latest", else: tag),
         digest: digest
       }}
    end
  end

  @doc "The name Docker uses in `fromImage` and `RepoDigests`, e.g. `alpine` or `localhost:5000/suite`."
  def name(%__MODULE__{host: @docker_hub, repository: "library/" <> repository}), do: repository
  def name(%__MODULE__{host: @docker_hub, repository: repository}), do: repository
  def name(%__MODULE__{host: host, repository: repository}), do: host <> "/" <> repository

  @doc "The `tag` parameter of a pull: the digest when there is one."
  def pull_tag(%__MODULE__{digest: nil, tag: tag}), do: tag
  def pull_tag(%__MODULE__{digest: digest}), do: digest

  def digest?(%__MODULE__{digest: digest}), do: digest != nil

  @doc "Picks this reference's digest out of an image's `RepoDigests`."
  def repo_digest(%__MODULE__{} = ref, repo_digests) do
    prefix = name(ref) <> "@"

    Enum.find_value(repo_digests, fn entry ->
      if String.starts_with?(entry, prefix), do: String.replace_prefix(entry, prefix, "")
    end)
  end

  defp split_tag(name) do
    last_colon = last_index(name, ":")

    if last_colon != nil and last_colon > (last_index(name, "/") || -1) do
      {binary_part(name, 0, last_colon),
       binary_part(name, last_colon + 1, byte_size(name) - last_colon - 1)}
    else
      {name, nil}
    end
  end

  defp split_host(name) do
    {host, repository} =
      case String.split(name, "/", parts: 2) do
        [first, rest] -> if host?(first), do: {first, rest}, else: {@docker_hub, name}
        [_] -> {@docker_hub, name}
      end

    host = if host == "index.docker.io", do: @docker_hub, else: host

    if host == @docker_hub and not String.contains?(repository, "/") and repository != "" do
      {host, "library/" <> repository}
    else
      {host, repository}
    end
  end

  defp host?(segment), do: String.contains?(segment, [".", ":"]) or segment == "localhost"

  defp last_index(string, pattern) do
    case :binary.matches(string, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
