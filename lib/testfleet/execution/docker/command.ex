defmodule TestFleet.Execution.Docker.Command do
  @moduledoc """
  The Docker Engine API operations TestFleet uses (main spec section 18). No other
  module builds Docker URLs.

  Failures return `{:error, %{status: status, message: message, reason: reason}}`.
  Responses meaning "already in that state" count as success, which makes stop, kill,
  and remove idempotent.

  `logs/2` and `wait/1` stream into the calling process (`into: :self`); parse the
  messages with `Req.parse_message/2`.
  """

  alias TestFleet.Execution.Docker.{Client, ImageRef, RegistryAuth}

  @min_api_version {1, 44}

  def ping do
    with {:ok, _} <- call([method: :get, url: "/_ping"], [200]),
         {:ok, %{body: %{"ApiVersion" => api_version}}} <-
           call([method: :get, url: "/version"], [200]) do
      if parse_version(api_version) >= @min_api_version do
        {:ok, api_version}
      else
        {:error,
         %{
           status: nil,
           message:
             "Docker Engine API #{api_version} is older than the required #{Client.api_version()}",
           reason: :api_version
         }}
      end
    end
  end

  def ensure_network(name) do
    case call([method: :get, url: "/networks/#{name}"], [200]) do
      {:ok, _} ->
        :ok

      {:error, %{status: 404}} ->
        body = %{"Name" => name, "Driver" => "bridge", "Labels" => %{"TestFleet" => "true"}}

        with {:ok, _} <- call([method: :post, url: "/networks/create", json: body], [201, 409]),
             do: :ok

      error ->
        error
    end
  end

  @doc """
  Pulls an image. Docker answers `200` and reports failures such as "unauthorized"
  inside the progress stream, so the whole stream is checked for errors.
  """
  def pull(%ImageRef{} = ref, auth) do
    options = [
      method: :post,
      url: "/images/create",
      params: [fromImage: ImageRef.name(ref), tag: ImageRef.pull_tag(ref)],
      headers: RegistryAuth.headers(auth, ref.host),
      decode_body: false,
      receive_timeout: 60_000
    ]

    with {:ok, %{body: body}} <- call(options, [200]) do
      case pull_error(body) do
        nil -> :ok
        message -> {:error, %{status: 200, message: message, reason: :pull_failed}}
      end
    end
  end

  @doc """
  Logs in to a registry without pulling (`POST /auth`), to check credentials.
  Nothing is stored: TestFleet still sends credentials with every pull.
  """
  def check_auth(host, %{username: username, password: password}) do
    body = %{
      username: username,
      password: password,
      serveraddress: RegistryAuth.server_address(host)
    }

    options = [method: :post, url: "/auth", json: body, receive_timeout: 30_000]
    with {:ok, _} <- call(options, [200]), do: :ok
  end

  def inspect_image(reference) do
    with {:ok, %{body: body}} <- call([method: :get, url: "/images/#{reference}/json"], [200]),
         do: {:ok, body}
  end

  @doc "Creates a container. A name that already exists returns an error with status 409."
  def create(name, spec) do
    options = [method: :post, url: "/containers/create", params: [name: name], json: spec]
    with {:ok, %{body: %{"Id" => id}}} <- call(options, [201]), do: {:ok, id}
  end

  def start(id) do
    with {:ok, _} <- call([method: :post, url: "/containers/#{id}/start"], [204, 304]), do: :ok
  end

  def inspect(id) do
    with {:ok, %{body: body}} <- call([method: :get, url: "/containers/#{id}/json"], [200]),
         do: {:ok, body}
  end

  @doc "Follows stdout and stderr with timestamps. `:since` is `LogDecoder.format_since/1` output."
  def logs(id, opts \\ []) do
    params =
      [follow: true, stdout: true, stderr: true, timestamps: true] ++
        if(since = opts[:since], do: [since: since], else: [])

    stream(method: :get, url: "/containers/#{id}/logs", params: params)
  end

  @doc "Streams a response that completes when the container is no longer running."
  def wait(id) do
    stream(method: :post, url: "/containers/#{id}/wait", params: [condition: "not-running"])
  end

  @doc "Sends SIGTERM, and SIGKILL after `grace_seconds`."
  def stop(id, grace_seconds) do
    options = [
      method: :post,
      url: "/containers/#{id}/stop",
      params: [t: grace_seconds],
      receive_timeout: (grace_seconds + 30) * 1000
    ]

    with {:ok, _} <- call(options, [204, 304, 404]), do: :ok
  end

  def kill(id) do
    with {:ok, _} <- call([method: :post, url: "/containers/#{id}/kill"], [204, 404, 409]),
         do: :ok
  end

  @doc """
  Downloads `path` from the container as a tar file to `destination`. Returns
  `{:error, %{status: 404}}` when the path does not exist.
  """
  def archive(id, path, destination) do
    options = [
      method: :get,
      url: "/containers/#{id}/archive",
      params: [path: path],
      decode_body: false,
      into: File.stream!(destination),
      receive_timeout: 60_000
    ]

    with {:ok, _} <- call(options, [200]), do: :ok
  end

  def remove(id) do
    options = [method: :delete, url: "/containers/#{id}", params: [force: true, v: true]]
    with {:ok, _} <- call(options, [204, 404, 409]), do: :ok
  end

  @doc "Lists containers, running or not, that carry all of the given labels."
  def list(labels) do
    options = [
      method: :get,
      url: "/containers/json",
      params: [all: true, filters: Jason.encode!(%{"label" => labels})]
    ]

    with {:ok, %{body: body}} <- call(options, [200]), do: {:ok, body}
  end

  defp stream(options) do
    call(options ++ [into: :self, receive_timeout: :infinity], [200])
  end

  defp call(options, ok_statuses) do
    with {:ok, %Req.Response{status: status} = response} <- Client.request(options) do
      if status in ok_statuses, do: {:ok, response}, else: {:error, Client.error(response)}
    end
  end

  defp pull_error(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"error" => error}} -> error
        _ -> nil
      end
    end)
  end

  defp parse_version(version) do
    version |> String.split(".") |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end
end
