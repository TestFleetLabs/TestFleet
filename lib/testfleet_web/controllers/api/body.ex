defmodule TestFleetWeb.API.Body do
  @moduledoc """
  Reads an API request's JSON body of string fields, and objects of string fields.
  Unknown fields are refused, so a typo like `"enviroment"` fails loudly instead of
  being ignored.
  """
  import Plug.Conn

  @doc """
  The body, when it is a JSON object with the `required` fields as non-empty
  strings, `optional` ones as strings, and no others:

      {:ok, body} | {:error, :bad_request, message} | {:error, :invalid, details}

  An optional `{field, keys}` is an object whose values are strings or null, with
  no keys but `keys`; its problems are named `"field.key"` in the details, so
  clients that print them need not know about nesting.
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
    allowed =
      Map.new(required ++ optional, fn
        {field, keys} -> {field, {:object, keys}}
        field -> {field, :string}
      end)

    details =
      Enum.flat_map(body, fn {field, value} ->
        case {Map.get(allowed, field), value} do
          {nil, _value} -> [{field, ["is not a known field"]}]
          {:string, value} when is_binary(value) -> []
          {:string, _value} -> [{field, ["must be a string"]}]
          {{:object, keys}, value} when is_map(value) -> validate_object(field, value, keys)
          {{:object, _keys}, _value} -> [{field, ["must be an object"]}]
        end
      end) ++
        for field <- required, blank?(body[field]), do: {field, ["can't be blank"]}

    if details == [], do: {:ok, body}, else: {:error, :invalid, Map.new(details)}
  end

  defp validate_object(field, object, keys) do
    Enum.flat_map(object, fn {key, value} ->
      cond do
        key not in keys -> [{"#{field}.#{key}", ["is not a known field"]}]
        is_binary(value) or is_nil(value) -> []
        true -> [{"#{field}.#{key}", ["must be a string"]}]
      end
    end)
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
