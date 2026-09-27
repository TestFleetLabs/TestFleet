defmodule TestFleet.Schedules.Schedule do
  @moduledoc """
  Runs a test definition against an environment of the same project at the times of
  a cron expression, in a time zone (main spec sections 6 and 28).

  `next_run_at` (UTC) is computed on create, when the cron expression or time zone
  changes, and when the schedule is re-enabled. A disabled schedule keeps it; the
  schedule tick ignores disabled schedules.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias TestFleet.Schedules.{Cron, Timezones}

  schema "schedules" do
    field :cron_expression, :string
    field :timezone, :string
    field :next_run_at, :utc_datetime
    field :overlap_policy, Ecto.Enum, values: [:skip, :queue, :allow], default: :skip
    field :enabled, :boolean, default: true

    belongs_to :test_definition, TestFleet.TestDefinitions.TestDefinition
    belongs_to :environment, TestFleet.Environments.Environment

    timestamps(type: :utc_datetime)
  end

  @doc """
  Options:

    * `:test_definition_ids` - the test definitions that may be chosen: the enabled
      ones of the project
    * `:environment_ids` - the environments of the project
    * `:now` - the time `next_run_at` is computed from
  """
  def changeset(schedule, attrs, opts) do
    schedule
    |> cast(attrs, [
      :test_definition_id,
      :environment_id,
      :cron_expression,
      :timezone,
      :overlap_policy,
      :enabled
    ])
    |> update_change(:cron_expression, &(&1 |> String.split() |> Enum.join(" ")))
    |> update_change(:timezone, &String.trim/1)
    |> validate_required([
      :test_definition_id,
      :environment_id,
      :cron_expression,
      :timezone,
      :overlap_policy
    ])
    |> validate_inclusion(:test_definition_id, Keyword.fetch!(opts, :test_definition_ids),
      message: "is not an enabled test definition of this project"
    )
    |> validate_inclusion(:environment_id, Keyword.fetch!(opts, :environment_ids),
      message: "is not an environment of this project"
    )
    |> validate_length(:cron_expression, max: 255)
    |> validate_change(:cron_expression, fn :cron_expression, expression ->
      case Cron.parse(expression) do
        {:ok, _} -> []
        {:error, message} -> [cron_expression: message]
      end
    end)
    |> validate_change(:timezone, fn :timezone, timezone ->
      if Timezones.valid?(timezone), do: [], else: [timezone: "is not a known time zone"]
    end)
    |> put_next_run_at(Keyword.get_lazy(opts, :now, &DateTime.utc_now/0))
    |> foreign_key_constraint(:test_definition_id)
    |> foreign_key_constraint(:environment_id)
  end

  defp put_next_run_at(changeset, now) do
    recompute? =
      changeset.data.id == nil or changed?(changeset, :cron_expression) or
        changed?(changeset, :timezone) or changed?(changeset, :enabled, to: true)

    invalid? =
      Keyword.has_key?(changeset.errors, :cron_expression) or
        Keyword.has_key?(changeset.errors, :timezone)

    with true <- recompute? and not invalid?,
         expression when is_binary(expression) <- get_field(changeset, :cron_expression),
         timezone when is_binary(timezone) <- get_field(changeset, :timezone),
         {:ok, cron} <- Cron.parse(expression) do
      case Cron.next_run(cron, timezone, now) do
        {:ok, next_run_at} -> put_change(changeset, :next_run_at, next_run_at)
        {:error, :never} -> add_error(changeset, :cron_expression, "never matches a date")
      end
    else
      _ -> changeset
    end
  end
end
