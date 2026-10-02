defmodule TestFleetWeb.ErrorJSON do
  @moduledoc """
  Renders errors on JSON requests, raised before or outside a controller (a
  malformed body, a crash), in the API's error format (Milestone 11, section 5):

      {"error": {"code": "bad_request", "message": "Bad Request"}}

  See config/config.exs.
  """

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    %{error: %{code: code(message), message: message}}
  end

  # "Not Found" -> "not_found"
  defp code(message), do: message |> String.downcase() |> String.replace(~r/[^a-z]+/, "_")
end
