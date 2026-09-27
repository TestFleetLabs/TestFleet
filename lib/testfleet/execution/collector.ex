defmodule TestFleet.Execution.Collector do
  @moduledoc """
  Copies `/TestFleet/artifacts` out of a stopped container and reads its JUnit files
  (main spec sections 10 and 12, Milestone 6 sections 4 and 5).

    * **Size limit:** the archive is downloaded with a byte cap. Over the limit,
      only `junit.xml` and `junit/` are kept, with a warning.
    * **Safe extraction:** the archive is untrusted. Only regular files are
      extracted; links, devices, and names that are absolute or contain `..` are
      skipped, with a warning.
    * **JUnit:** `junit.xml` and `junit/*.xml` are parsed with
      `TestFleet.Results.JUnit`. Files that cannot be parsed are skipped with a
      warning; if none can, the run has no JUnit.

  A missing artifacts directory is not an error: the run has no artifacts.
  """

  alias TestFleet.Execution.Docker.Command
  alias TestFleet.Results.JUnit

  @artifacts_dir "/TestFleet/artifacts"
  @max_junit_bytes 50 * 1024 * 1024

  @type collection :: %{
          artifacts: [%{path: String.t(), size_bytes: non_neg_integer()}],
          test_results: [map()] | nil,
          junit: %{failed: non_neg_integer()} | nil,
          warnings: [String.t()]
        }

  def artifacts_dir, do: @artifacts_dir

  @doc "An empty collection: no artifacts, no JUnit."
  def empty, do: %{artifacts: [], test_results: nil, junit: nil, warnings: []}

  @doc """
  Collects into `path`, which is emptied first (a reattached run collects again).
  `max_bytes` caps the archive; `nil` means no limit.
  """
  @spec collect(String.t(), Path.t() | nil, pos_integer() | nil) :: collection()
  def collect(_container_id, nil, _max_bytes), do: empty()

  def collect(container_id, path, max_bytes) do
    File.rm_rf!(path)
    File.mkdir_p!(path)

    warnings = fetch(container_id, path, max_bytes)
    {test_results, junit, junit_warnings} = read_junit(path)

    %{
      artifacts: list_artifacts(path),
      test_results: test_results,
      junit: junit,
      warnings: warnings ++ junit_warnings
    }
  end

  ## Downloading

  # Returns the warnings.
  defp fetch(container_id, path, max_bytes) do
    case download(container_id, @artifacts_dir, path, max_bytes, "artifacts") do
      {:ok, warnings} ->
        warnings

      {:error, %{status: 404}} ->
        []

      {:error, %{reason: :too_large}} ->
        limit = format_mib(max_bytes)

        junit_warnings =
          for name <- ["junit.xml", "junit"],
              {:ok, warnings} <-
                [download(container_id, "#{@artifacts_dir}/#{name}", path, max_bytes, ".")],
              warning <- warnings,
              do: warning

        ["Artifacts exceeded #{limit}; only the JUnit files were kept" | junit_warnings]

      {:error, error} ->
        ["Artifacts could not be collected: #{error.message}"]
    end
  end

  # Docker puts an archived directory's contents under an entry named after it
  # (`artifacts/…`), and an archived file at the top (`junit.xml`). `root` is what
  # to move into `path` after extracting.
  defp download(container_id, source, path, max_bytes, root) do
    tar = path <> ".tar"
    staging = path <> ".extract"

    try do
      with :ok <- Command.archive(container_id, source, tar, max_bytes) do
        File.rm_rf!(staging)
        File.mkdir_p!(staging)
        skipped = extract(tar, staging)
        move_contents(Path.join(staging, root), path)
        {:ok, skipped_warning(skipped)}
      end
    after
      File.rm(tar)
      File.rm_rf(staging)
    end
  end

  ## Extracting

  # Extracts only regular files with safe names. Returns how many entries were
  # skipped (directories are created as needed, not counted).
  defp extract(tar, destination) do
    {:ok, entries} = :erl_tar.table(String.to_charlist(tar), [:verbose])

    {files, skipped} =
      Enum.reduce(entries, {[], 0}, fn {name, type, _size, _mtime, _mode, _uid, _gid},
                                       {files, skipped} ->
        cond do
          type == :directory -> {files, skipped}
          type == :regular and safe_name?(List.to_string(name)) -> {[name | files], skipped}
          true -> {files, skipped + 1}
        end
      end)

    if files != [] do
      :ok =
        :erl_tar.extract(String.to_charlist(tar), [
          {:cwd, String.to_charlist(destination)},
          {:files, files}
        ])
    end

    skipped
  end

  # Relative, without `..`; backslashes and drive letters would be separators on Windows.
  defp safe_name?(name) do
    segments = String.split(name, "/")

    not String.starts_with?(name, "/") and ".." not in segments and
      not String.contains?(name, ["\\", ":", <<0>>])
  end

  defp skipped_warning(0), do: []

  defp skipped_warning(count),
    do: [
      "#{count} #{if count == 1, do: "entry was", else: "entries were"} skipped: links or unsafe paths"
    ]

  defp move_contents(source, destination) do
    if File.dir?(source) do
      for entry <- File.ls!(source) do
        target = Path.join(destination, entry)
        File.rm_rf!(target)
        File.rename!(Path.join(source, entry), target)
      end
    end

    :ok
  end

  defp list_artifacts(path) do
    # Path.wildcard/2 needs forward slashes, which Path.expand/1 produces on Windows too.
    path = Path.expand(path)

    path
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&%{path: Path.relative_to(&1, path), size_bytes: File.stat!(&1).size})
    |> Enum.sort_by(& &1.path)
  end

  ## JUnit

  defp read_junit(path) do
    path = Path.expand(path)

    files =
      [Path.join(path, "junit.xml") | Path.wildcard(Path.join([path, "junit", "*.xml"]))]
      |> Enum.filter(&File.regular?/1)

    {parsed, warnings} =
      Enum.reduce(files, {[], []}, fn file, {parsed, warnings} ->
        name = Path.relative_to(file, path)

        case read_junit_file(file) do
          {:ok, cases} ->
            {[Enum.map(cases, &Map.put(&1, :file, name)) | parsed], warnings}

          {:error, reason} ->
            {parsed, ["#{name} could not be parsed: #{reason}" | warnings]}
        end
      end)

    case parsed do
      [] ->
        {nil, nil, Enum.reverse(warnings)}

      parsed ->
        test_results = parsed |> Enum.reverse() |> Enum.concat()
        failed = Enum.count(test_results, &(&1.status in [:failed, :error]))
        {test_results, %{failed: failed}, Enum.reverse(warnings)}
    end
  end

  defp read_junit_file(file) do
    if File.stat!(file).size > @max_junit_bytes,
      do: {:error, "larger than #{format_mib(@max_junit_bytes)}"},
      else: file |> File.read!() |> JUnit.parse()
  end

  defp format_mib(bytes) do
    mib = bytes / (1024 * 1024)
    if mib == trunc(mib), do: "#{trunc(mib)} MiB", else: "#{Float.round(mib, 1)} MiB"
  end
end
