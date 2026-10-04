defmodule TestFleetWeb.ArtifactResponse do
  @moduledoc """
  Sends one artifact's file, for the web UI (`TestFleetWeb.ArtifactController`)
  and the API, so the two cannot
  drift apart.

  An artifact is someone else's file, so:

    * Callers look the name up in the run's `artifacts` rows; a request never
      builds a file path.
    * `Content-Type` comes from the row, with `X-Content-Type-Options: nosniff`.
    * Every response except PDF carries `Content-Security-Policy: sandbox …`
      without `allow-same-origin`. An HTML report still runs its scripts, but in
      an opaque origin, away from TestFleet's cookies and pages. SVG and XML can
      run scripts too, so the header is not limited to HTML. PDF is exempt
      because browsers refuse to show PDFs in a sandboxed document.
    * With `disposition: :auto` (the web UI), images, videos, audio, PDF, and text
      are shown inline and everything else is downloaded; `:attachment` (the API)
      always downloads.

  Single byte ranges are supported, so videos can seek.
  """
  import Plug.Conn

  alias TestFleet.Artifacts
  alias TestFleet.Artifacts.Artifact

  @sandbox "sandbox allow-scripts allow-popups allow-forms"

  @doc """
  Sends the artifact's file, or returns `:error` when the file is missing (a crash
  during retention leaves rows without files).
  """
  def send_artifact(conn, %Artifact{} = artifact, opts \\ []) do
    path = Artifacts.path(artifact)

    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        conn
        |> put_resp_header("content-type", artifact.content_type)
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header(
          "content-disposition",
          disposition(artifact, Keyword.get(opts, :disposition, :auto))
        )
        |> put_sandbox(artifact.content_type)
        |> send_range(path, size)

      _ ->
        :error
    end
  end

  defp put_sandbox(conn, "application/pdf"), do: conn

  defp put_sandbox(conn, _content_type),
    do: put_resp_header(conn, "content-security-policy", @sandbox)

  ## Content-Disposition

  defp disposition(artifact, disposition) do
    type =
      if disposition == :auto and inline?(artifact.content_type),
        do: "inline",
        else: "attachment"

    filename = Path.basename(artifact.name)

    # An ASCII fallback, and the exact name per RFC 6266 / 5987.
    fallback = String.replace(filename, ~r/[^A-Za-z0-9._ -]/, "_")

    ~s(#{type}; filename="#{fallback}"; filename*=UTF-8''#{URI.encode(filename, &URI.char_unreserved?/1)})
  end

  @doc false
  def inline?("application/pdf"), do: true

  def inline?(content_type),
    do: String.starts_with?(content_type, ["image/", "video/", "audio/", "text/"])

  ## Ranges

  defp send_range(conn, path, size) do
    case get_req_header(conn, "range") do
      [range] ->
        case parse_range(range, size) do
          {:ok, first, last} ->
            conn
            |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
            |> send_file(206, path, first, last - first + 1)

          :unsatisfiable ->
            conn
            |> put_resp_header("content-range", "bytes */#{size}")
            |> send_resp(416, "")

          # Several ranges, or a malformed header: the whole file.
          :ignore ->
            send_file(conn, 200, path)
        end

      _ ->
        send_file(conn, 200, path)
    end
  end

  @doc false
  def parse_range("bytes=" <> spec, size) do
    case String.split(spec, "-", parts: 2) do
      [first, ""] ->
        with {:ok, first} <- parse_int(first) do
          if first < size, do: {:ok, first, size - 1}, else: :unsatisfiable
        end

      ["", suffix] ->
        with {:ok, suffix} <- parse_int(suffix) do
          if suffix > 0 and size > 0,
            do: {:ok, max(size - suffix, 0), size - 1},
            else: :unsatisfiable
        end

      [first, last] ->
        with {:ok, first} <- parse_int(first), {:ok, last} <- parse_int(last) do
          cond do
            first > last -> :ignore
            first >= size -> :unsatisfiable
            true -> {:ok, first, min(last, size - 1)}
          end
        end
    end
  end

  def parse_range(_range, _size), do: :ignore

  defp parse_int(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> :ignore
    end
  end
end
