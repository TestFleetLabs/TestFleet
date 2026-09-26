defmodule TestFleet.Execution.Docker.RegistryAuth do
  @moduledoc """
  Builds the `X-Registry-Auth` header for a single pull (main spec section 38).

  TestFleet never runs `docker login` and never writes a Docker config file.
  """

  @docker_hub_server "https://index.docker.io/v1/"

  @spec headers(%{username: String.t(), password: String.t()} | nil, String.t()) ::
          [{String.t(), String.t()}]
  def headers(nil, _host), do: []

  def headers(%{username: username, password: password}, host) do
    auth = %{username: username, password: password, serveraddress: server_address(host)}
    [{"x-registry-auth", auth |> Jason.encode!() |> Base.url_encode64()}]
  end

  defp server_address("docker.io"), do: @docker_hub_server
  defp server_address(host), do: host
end
