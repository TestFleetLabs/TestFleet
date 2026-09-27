defmodule TestFleet.Registries do
  @moduledoc """
  Registry credentials, resolved by the host of an image reference (main spec
  section 38). Images whose host has no registry are pulled anonymously.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Execution.Docker.{Command, ImageRef}
  alias TestFleet.Registries.Registry
  alias TestFleet.Repo

  def list_registries do
    Repo.all(from r in Registry, order_by: [asc: fragment("lower(?)", r.name)])
  end

  def get_registry!(id), do: Repo.get!(Registry, id)

  @doc "The registry holding credentials for `image`, or `nil` to pull anonymously."
  def get_registry_for_image(image) do
    case ImageRef.parse(image) do
      {:ok, %ImageRef{host: host}} -> Repo.get_by(Registry, host: host)
      {:error, _} -> nil
    end
  end

  def create_registry(attrs) do
    %Registry{}
    |> Registry.changeset(attrs)
    |> Repo.insert()
  end

  def update_registry(%Registry{} = registry, attrs) do
    registry
    |> Registry.changeset(attrs)
    |> Repo.update()
  end

  def delete_registry(%Registry{} = registry), do: Repo.delete(registry)

  def change_registry(%Registry{} = registry, attrs \\ %{}) do
    Registry.changeset(registry, attrs)
  end

  @doc """
  Removes the password, so that a struct handed to a template or a form cannot
  leak it.
  """
  def redact(%Registry{} = registry), do: %{registry | password: nil}

  @doc """
  Logs in to the registry through the Docker Engine (`POST /auth`) without pulling.

  `registry` is the stored registry, or a new `%Registry{}`; `attrs` are the form
  values. An empty password uses the stored one, as when saving.
  """
  @spec test_connection(%Registry{}, map()) :: :ok | {:error, String.t()}
  def test_connection(%Registry{} = registry, attrs) do
    changeset = change_registry(registry, attrs)
    host = Ecto.Changeset.get_field(changeset, :host)
    username = Ecto.Changeset.get_field(changeset, :username)
    password = Ecto.Changeset.get_field(changeset, :password)

    cond do
      Enum.any?([host, username, password], &(&1 in [nil, ""])) ->
        {:error, "Enter the host, username, and password first."}

      Keyword.has_key?(changeset.errors, :host) ->
        {:error, "Fix the host first."}

      true ->
        case Command.check_auth(host, %{username: username, password: password}) do
          :ok -> :ok
          {:error, error} -> {:error, error.message}
        end
    end
  end
end
