defmodule TestFleet.Registries do
  @moduledoc """
  Registry credentials, resolved by the host of an image reference.
  Images whose host has no registry are pulled anonymously.
  """

  import Ecto.Query, warn: false

  alias TestFleet.Accounts.Scope
  alias TestFleet.Execution.Docker.{Command, ImageRef}
  alias TestFleet.Registries.Registry
  alias TestFleet.Repo

  @doc "The scope's organization's registries, by name."
  def list_registries(%Scope{} = scope) do
    Repo.all(
      from r in Registry,
        where: r.organization_id == ^organization_id(scope),
        order_by: [asc: fragment("lower(?)", r.name)]
    )
  end

  def get_registry!(%Scope{} = scope, id),
    do: Repo.get_by!(Registry, organization_id: organization_id(scope), id: id)

  @doc """
  The organization's registry holding credentials for `image`, or `nil` to pull
  anonymously. Takes the scope (the web layer) or an organization id (building a
  run's request).
  """
  def get_registry_for_image(%Scope{} = scope, image),
    do: get_registry_for_image(organization_id(scope), image)

  def get_registry_for_image(organization_id, image) when is_integer(organization_id) do
    case ImageRef.parse(image) do
      {:ok, %ImageRef{host: host}} ->
        Repo.get_by(Registry, organization_id: organization_id, host: host)

      {:error, _} ->
        nil
    end
  end

  def create_registry(%Scope{} = scope, attrs) do
    %Registry{organization_id: organization_id(scope)}
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

  defp organization_id(%Scope{organization: %{id: id}}), do: id
end
