defmodule TestFleetWeb.API.RunFileJSON do
  @moduledoc "A run's artifacts as the API lists them."
  use TestFleetWeb, :verified_routes

  def artifacts(%{run: run, artifacts: artifacts}) do
    %{
      artifacts:
        for artifact <- artifacts do
          %{
            name: artifact.name,
            content_type: artifact.content_type,
            size_bytes: artifact.size_bytes,
            url: url(~p"/api/v1/runs/#{run}/artifacts/#{String.split(artifact.name, "/")}")
          }
        end
    }
  end
end
