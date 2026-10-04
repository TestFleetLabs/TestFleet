defmodule TestFleetWeb.API.Body do
  @moduledoc """
  Reads an API request's JSON body of string fields.
  Unknown fields are refused, so a typo like `"enviroment"` fails loudly instead of
  being ignored.
  """
  import Plug.Conn

  @doc """
  The body, when it is a JSON object with the `required` fields as non-empty
  strings, `optional` ones as strings, and no others:

      {:ok, body} | {:error, :bad_request, message} | {:error, :invalid, details}
  """
  def fetch(conn, required, optional \\ []) do
    cond do
      # curl -d sends a form unless told otherwise
      conn.body_params != %{} and not json?(conn) ->
        {:error, :bad_request, "Send the body as JSON (Content-Type: application/json)."}

      Map.has_key?(conn.body_params, "_json") ->
        {:error, :bad_request, "The body must be a JSON object."}

      true ->
        validate(conn.body_params, required, optional)
    end
  end

  defp validate(body, required, optional) do
    allowed = required ++ optional

    details =
      Enum.flat_map(body, fn {field, value} ->
        cond do
          field not in allowed -> [{field, ["is not a known field"]}]
          not is_binary(value) -> [{field, ["must be a string"]}]
          true -> []
        end
      end) ++
        for field <- required, blank?(body[field]), do: {field, ["can't be blank"]}

    if details == [], do: {:ok, body}, else: {:error, :invalid, Map.new(details)}
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  # Reported as "must be a string"
  defp blank?(_value), do: false

  defp json?(conn) do
    case get_req_header(conn, "content-type") do
      [type | _] -> String.starts_with?(type, "application/json")
      [] -> false
    end
  end
end
