defmodule TestFleet.TestDefinitions.TestDefinition do
  @moduledoc """
  The test suite of a project: which image to run, with which command and limits.

  Durations and sizes are stored in seconds and bytes. The form works in minutes
  and MiB through virtual fields (`timeout_minutes`, `memory_limit_mib`,
  `shm_size_mib`, `command_text`); when one of them is submitted, it sets the
  stored field. Callers that pass the stored fields directly are unaffected.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import TestFleet.Changesets, only: [update_present: 3]

  alias TestFleet.Execution.Docker.ImageRef
  alias TestFleet.Slug

  @mib 1024 * 1024
  @max_timeout_seconds 86_400
  # Docker rejects memory limits below 6 MB
  @min_memory_mib 6
  @max_arguments 100
  @max_argument_length 4096

  schema "test_definitions" do
    field :name, :string
    field :slug, :string
    field :description, :string

    field :image, :string
    field :command, {:array, :string}, default: []

    field :timeout_seconds, :integer, default: 1800
    field :cpu_limit, :float
    field :memory_limit, :integer
    field :shm_size_bytes, :integer, default: 2048 * @mib

    field :enabled, :boolean, default: true

    # Form fields, see the moduledoc
    field :timeout_minutes, :integer, virtual: true
    field :memory_limit_mib, :integer, virtual: true
    field :shm_size_mib, :integer, virtual: true
    field :command_text, :string, virtual: true

    belongs_to :project, TestFleet.Projects.Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(test_definition, attrs) do
    test_definition
    |> cast(attrs, [
      :name,
      :slug,
      :description,
      :image,
      :command,
      :timeout_seconds,
      :cpu_limit,
      :memory_limit,
      :shm_size_bytes,
      :enabled,
      :timeout_minutes,
      :memory_limit_mib,
      :shm_size_mib,
      :command_text
    ])
    |> update_present(:image, &String.trim/1)
    |> from_form(:timeout_minutes, :timeout_seconds, 60,
      required: true,
      range: [greater_than_or_equal_to: 1, less_than_or_equal_to: div(@max_timeout_seconds, 60)]
    )
    |> from_form(:memory_limit_mib, :memory_limit, @mib,
      required: false,
      range: [greater_than_or_equal_to: @min_memory_mib]
    )
    |> from_form(:shm_size_mib, :shm_size_bytes, @mib,
      required: true,
      range: [greater_than_or_equal_to: 1]
    )
    |> command_from_text()
    |> validate_required([:name, :image, :timeout_seconds, :shm_size_bytes])
    |> validate_length(:name, max: 100)
    |> validate_length(:description, max: 2000)
    |> validate_length(:image, max: 1000)
    |> validate_number(:timeout_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_timeout_seconds
    )
    |> validate_number(:cpu_limit, greater_than: 0, less_than_or_equal_to: 256)
    |> validate_number(:memory_limit, greater_than_or_equal_to: @min_memory_mib * @mib)
    |> validate_number(:shm_size_bytes, greater_than_or_equal_to: @mib)
    |> validate_image()
    |> validate_command()
    |> Slug.put_and_validate()
    |> unique_constraint(:slug, name: :test_definitions_project_id_slug_index)
  end

  @doc "Fills the form fields from the stored ones. Timeouts round up to whole minutes."
  def put_form_fields(%__MODULE__{} = test_definition) do
    %{
      test_definition
      | timeout_minutes:
          test_definition.timeout_seconds && ceil_div(test_definition.timeout_seconds, 60),
        memory_limit_mib:
          test_definition.memory_limit && ceil_div(test_definition.memory_limit, @mib),
        shm_size_mib:
          test_definition.shm_size_bytes && ceil_div(test_definition.shm_size_bytes, @mib),
        command_text: Enum.join(test_definition.command || [], "\n")
    }
  end

  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)

  # Only when the form field was submitted, so that callers using the stored field
  # are not overridden. Validation runs on the form field too, so that its errors
  # appear next to the input, in the input's unit.
  defp from_form(changeset, form_field, field, factor, opts) do
    if Map.has_key?(changeset.params, Atom.to_string(form_field)) do
      changeset =
        if opts[:required], do: validate_required(changeset, [form_field]), else: changeset

      changeset
      |> validate_number(form_field, opts[:range])
      # get_field, not get_change: an unchanged form value is not a change, but still
      # the value to store.
      |> put_change(field, scale(get_field(changeset, form_field), factor))
    else
      changeset
    end
  end

  defp scale(nil, _factor), do: nil
  defp scale(value, factor), do: value * factor

  # One argument per line. Lines are trimmed and empty lines dropped.
  defp command_from_text(changeset) do
    if Map.has_key?(changeset.params, "command_text") do
      command =
        (get_field(changeset, :command_text) || "")
        |> String.split(["\r\n", "\n"])
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      put_change(changeset, :command, command)
    else
      changeset
    end
  end

  defp validate_image(changeset) do
    validate_change(changeset, :image, fn :image, image ->
      case ImageRef.parse(image) do
        {:ok, _} -> []
        {:error, _} -> [image: "is not a valid image reference"]
      end
    end)
  end

  defp validate_command(changeset) do
    field = if Map.has_key?(changeset.params, "command_text"), do: :command_text, else: :command

    validate_change(changeset, :command, fn :command, command ->
      cond do
        length(command) > @max_arguments ->
          [{field, "has more than #{@max_arguments} arguments"}]

        Enum.any?(command, &(String.length(&1) > @max_argument_length)) ->
          [{field, "has an argument longer than #{@max_argument_length} characters"}]

        true ->
          []
      end
    end)
  end
end
