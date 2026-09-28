defmodule TestFleet.Environments.Variable do
  @moduledoc """
  An environment variable passed to the test container (main spec sections 6 and 12).

  Every value is encrypted at rest. Secret values are never sent back to the
  browser and are masked in logs; they must therefore be long enough to mask
  reliably (main spec section 21).

  When editing a secret, an empty value means "keep the current one".
  """
  use Ecto.Schema
  import Ecto.Changeset
  import TestFleet.Changesets, only: [update_present: 3]

  @key_format ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @reserved_prefix "testfleet_"
  @min_secret_length 6

  schema "environment_variables" do
    field :key, :string
    field :value, TestFleet.Encrypted.Binary, source: :value_encrypted, redact: true
    field :secret, :boolean, default: false

    belongs_to :environment, TestFleet.Environments.Environment

    timestamps(type: :utc_datetime)
  end

  def min_secret_length, do: @min_secret_length

  @doc false
  def changeset(variable, attrs) do
    variable
    |> cast(attrs, [:key, :secret])
    |> cast_value(attrs)
    |> update_present(:key, &String.trim/1)
    |> validate_required([:key])
    |> validate_length(:key, max: 255)
    |> validate_format(:key, @key_format,
      message:
        "must start with a letter or underscore and contain only letters, digits, and underscores"
    )
    |> validate_change(:key, fn :key, key ->
      if String.starts_with?(String.downcase(key), @reserved_prefix),
        do: [key: "the TestFleet_ prefix is reserved"],
        else: []
    end)
    |> validate_secret()
    |> unique_constraint(:key, name: :environment_variables_environment_id_key_index)
  end

  # An existing secret keeps its value when the field is left empty.
  defp cast_value(changeset, attrs) do
    value = attrs["value"] || attrs[:value]
    keep_secret? = changeset.data.id != nil and changeset.data.secret and value in [nil, ""]

    if keep_secret? do
      changeset
    else
      changeset
      |> cast(attrs, [:value], empty_values: [nil])
      |> then(fn cs ->
        if get_field(cs, :value) == nil, do: put_change(cs, :value, ""), else: cs
      end)
    end
  end

  defp validate_secret(changeset) do
    was_secret? = changeset.data.id != nil and changeset.data.secret
    secret? = get_field(changeset, :secret)
    value_changed? = Map.has_key?(changeset.changes, :value)

    cond do
      was_secret? and not secret? and not value_changed? ->
        add_error(changeset, :value, "enter a new value to make this variable non-secret")

      # Checked on the field, not the change: making an existing value secret must
      # validate it too.
      secret? and (value_changed? or not was_secret?) and
          String.length(get_field(changeset, :value) || "") < @min_secret_length ->
        add_error(
          changeset,
          :value,
          "secrets need at least %{count} characters to be masked in logs",
          count: @min_secret_length,
          validation: :length,
          kind: :min
        )

      true ->
        changeset
    end
  end
end
