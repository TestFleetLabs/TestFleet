defmodule TestFleetWeb.API.FallbackController do
  @moduledoc """
  Turns the API controllers' errors into responses (Milestone 11, section 5).
  """
  use TestFleetWeb, :controller

  import TestFleetWeb.API.Error

  def call(conn, {:error, :bad_request, message}),
    do: send_error(conn, 400, "bad_request", message)

  def call(conn, {:error, :not_found, message}), do: send_error(conn, 404, "not_found", message)

  # Removed by retention (Milestone 6, section 8)
  def call(conn, {:error, :expired, message}), do: send_error(conn, 410, "expired", message)

  def call(conn, {:error, :test_definition_disabled}) do
    send_error(
      conn,
      409,
      "test_definition_disabled",
      "The test definition is disabled. Enable it in TestFleet to start runs."
    )
  end

  def call(conn, {:error, :invalid, details}) do
    send_error(conn, 422, "invalid", "The request is invalid.", details)
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    details =
      Ecto.Changeset.traverse_errors(changeset, &TestFleetWeb.CoreComponents.translate_error/1)

    send_error(conn, 422, "invalid", "The request is invalid.", details)
  end
end
