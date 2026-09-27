defmodule TestFleet.Schedules.Cron do
  @moduledoc """
  Next occurrences of a cron expression in a time zone (main spec section 28).

  Occurrences are computed on local wall-clock time and converted to UTC:

    * a local time that does not exist (spring forward) moves to the first valid
      instant after the gap,
    * a local time that occurs twice (fall back) uses the first occurrence.

  Every local wall-clock time therefore runs at most once. A consequence: during the
  repeated hour of a fall-back night, a schedule that runs every few minutes pauses
  until the hour is over, because those local times already ran.
  """

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser

  # Skipped candidates before giving up: covers every minute of a repeated DST hour.
  @max_attempts 120

  @doc "Parses a standard 5-field cron expression, or an alias such as `@daily`."
  @spec parse(String.t()) :: {:ok, CronExpression.t()} | {:error, String.t()}
  def parse(expression) when is_binary(expression) do
    fields = String.split(expression)
    expression = Enum.join(fields, " ")
    fields = length(fields)

    # Crontab also accepts a sixth field (year); standard cron has five.
    if String.starts_with?(expression, "@") or fields == 5 do
      case Parser.parse(expression) do
        {:ok, %CronExpression{reboot: true}} -> {:error, "@reboot is not a schedule"}
        {:ok, cron} -> {:ok, cron}
        {:error, _message} -> {:error, "is not a valid cron expression"}
      end
    else
      {:error, "needs five fields: minute hour day month weekday"}
    end
  end

  @doc "The first occurrence strictly after `since` (UTC), as a UTC `DateTime` in whole minutes."
  @spec next_run(CronExpression.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, :never}
  def next_run(%CronExpression{} = cron, timezone, %DateTime{} = since) do
    local =
      since
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_naive()
      |> NaiveDateTime.truncate(:second)
      |> Map.put(:second, 0)
      |> NaiveDateTime.add(60)

    find(cron, timezone, since, local, @max_attempts)
  end

  @doc "The next `count` occurrences after `since`; fewer if the expression stops matching."
  @spec next_runs(CronExpression.t(), String.t(), DateTime.t(), pos_integer()) :: [DateTime.t()]
  def next_runs(cron, timezone, since, count) do
    {runs, _} =
      Enum.reduce_while(1..count, {[], since}, fn _, {runs, since} ->
        case next_run(cron, timezone, since) do
          {:ok, run} -> {:cont, {[run | runs], run}}
          {:error, :never} -> {:halt, {runs, since}}
        end
      end)

    Enum.reverse(runs)
  end

  defp find(_cron, _timezone, _since, _from, 0), do: {:error, :never}

  defp find(cron, timezone, since, from, attempts) do
    case Crontab.Scheduler.get_next_run_date(cron, from) do
      {:ok, local} ->
        utc = to_utc(local, timezone)

        # A repeated local time whose first occurrence already passed.
        if DateTime.after?(utc, since),
          do: {:ok, utc},
          else: find(cron, timezone, since, NaiveDateTime.add(local, 60), attempts - 1)

      {:error, _} ->
        {:error, :never}
    end
  end

  defp to_utc(local, timezone) do
    datetime =
      case DateTime.from_naive(local, timezone) do
        {:ok, datetime} -> datetime
        {:ambiguous, first, _second} -> first
        {:gap, _just_before, just_after} -> just_after
      end

    DateTime.shift_zone!(datetime, "Etc/UTC")
  end
end
