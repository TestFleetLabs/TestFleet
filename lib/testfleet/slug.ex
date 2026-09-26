defmodule TestFleet.Slug do
  @moduledoc """
  URL identifiers for projects, environments, and test definitions: lowercase
  letters, digits, and single dashes.

  An empty slug is generated from another field (usually the name). A slug entered
  by hand is validated, never silently rewritten.
  """

  import Ecto.Changeset

  @format ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/
  @max_length 60
  # Taken by routes such as /projects/new
  @reserved ~w(new edit)

  @spec slugify(String.t() | nil) :: String.t()
  def slugify(nil), do: ""

  def slugify(text) do
    text
    |> String.normalize(:nfd)
    |> String.replace(~r/\p{Mn}/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, @max_length)
    |> String.trim_trailing("-")
  end

  @doc "Generates `field` from `source` when it is empty, then validates it."
  def put_and_validate(changeset, source \\ :name, field \\ :slug) do
    changeset =
      if get_field(changeset, field) in [nil, ""] do
        put_change(changeset, field, changeset |> get_field(source) |> slugify())
      else
        changeset
      end

    changeset
    |> validate_required([field])
    |> validate_length(field, max: @max_length)
    |> validate_format(field, @format,
      message: "use lowercase letters, digits, and single dashes"
    )
    |> validate_exclusion(field, @reserved, message: "is reserved")
  end
end
