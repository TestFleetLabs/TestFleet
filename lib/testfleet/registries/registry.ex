defmodule TestFleet.Registries.Registry do
  @moduledoc """
  Credentials for a container registry.

  `host` is matched against the host of image references, so it is stored the way
  `TestFleet.Execution.Docker.ImageRef` reports hosts: lowercase, without scheme or
  path, and Docker Hub as `docker.io`.

  The password is encrypted at rest and never sent back to the browser. When
  editing, an empty password means "keep the current one".
  """
  use Ecto.Schema
  import Ecto.Changeset
  import TestFleet.Changesets, only: [update_present: 3]

  @host_format ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*(:[0-9]{1,5})?$/

  schema "registries" do
    field :name, :string
    field :host, :string
    field :username, :string
    field :password, TestFleet.Encrypted.Binary, source: :password_encrypted, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(registry, attrs) do
    registry
    |> cast(attrs, [:name, :host, :username])
    |> cast_password(attrs)
    |> update_present(:name, &String.trim/1)
    |> update_present(:host, &normalize_host/1)
    |> update_present(:username, &String.trim/1)
    |> validate_required([:name, :host, :username])
    |> validate_length(:name, max: 100)
    |> validate_length(:host, max: 255)
    |> validate_length(:username, max: 255)
    |> validate_length(:password, max: 4096)
    |> validate_host()
    |> unique_constraint(:host, message: "already has credentials")
  end

  # An existing registry keeps its password when the field is left empty.
  defp cast_password(changeset, attrs) do
    password = attrs["password"] || attrs[:password]

    cond do
      password not in [nil, ""] -> cast(changeset, attrs, [:password])
      changeset.data.id == nil -> add_error(changeset, :password, "can't be blank")
      true -> changeset
    end
  end

  defp normalize_host(host) do
    case host |> String.trim() |> String.downcase() do
      "index.docker.io" -> "docker.io"
      host -> host
    end
  end

  defp validate_host(changeset) do
    validate_change(changeset, :host, fn :host, host ->
      cond do
        String.contains?(host, "://") -> [host: "enter the host without http:// or https://"]
        String.contains?(host, "/") -> [host: "enter the host only, without a path"]
        not Regex.match?(@host_format, host) -> [host: "is not a valid host name"]
        true -> []
      end
    end)
  end
end
