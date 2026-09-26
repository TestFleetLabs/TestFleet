defmodule TestFleet.Execution.Docker.Client do
  @moduledoc """
  Req client for the Docker Engine HTTP API.

  The endpoint comes from `DOCKER_HOST` (see `config/runtime.exs`): `tcp://host:port`
  for the socket proxy, or `unix:///path/to/docker.sock`. Windows named pipes are not
  supported; use the socket proxy from `compose.yaml` instead.
  """

  @api_version "1.44"

  @type error :: %{status: pos_integer() | nil, message: String.t(), reason: term()}

  def api_version, do: @api_version

  @spec request(keyword()) :: {:ok, Req.Response.t()} | {:error, error()}
  def request(options) do
    case Req.request(new(), options) do
      {:ok, response} ->
        {:ok, response}

      {:error, exception} ->
        {:error,
         %{
           status: nil,
           message: "Docker Engine unreachable: " <> Exception.message(exception),
           reason: exception
         }}
    end
  end

  @doc "Turns an unexpected response into an error, using Docker's `message` when present."
  @spec error(Req.Response.t()) :: error()
  def error(%Req.Response{status: status, body: body}) do
    message =
      case message(body) do
        "" -> "Docker Engine returned HTTP #{status}"
        message -> message
      end

    %{status: status, message: message, reason: :http_error}
  end

  defp message(%Req.Response.Async{} = body), do: body |> Enum.join() |> message()
  defp message(%{"message" => message}), do: message

  defp message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"message" => message}} -> message
      _ -> String.trim(body)
    end
  end

  defp message(body), do: inspect(body)

  defp new do
    :testfleet
    |> Application.fetch_env!(TestFleet.Execution.Docker)
    |> Keyword.fetch!(:host)
    |> connection_options()
    |> Keyword.put(:retry, false)
    |> Req.new()
  end

  defp connection_options("tcp://" <> address),
    do: [base_url: "http://#{address}/v#{@api_version}"]

  defp connection_options("http://" <> _ = url),
    do: [base_url: "#{String.trim_trailing(url, "/")}/v#{@api_version}"]

  defp connection_options("unix://" <> path),
    do: [base_url: "http://localhost/v#{@api_version}", unix_socket: path]

  defp connection_options(host) do
    raise ArgumentError,
          "unsupported DOCKER_HOST #{inspect(host)}, expected tcp://, http:// or unix://"
  end
end
