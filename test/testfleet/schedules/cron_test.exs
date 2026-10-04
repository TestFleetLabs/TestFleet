defmodule TestFleet.Schedules.CronTest do
  use ExUnit.Case, async: true

  alias TestFleet.Schedules.Cron

  # Europe/Vienna in 2026: clocks go forward on 29 March at 02:00 (to 03:00 CEST),
  # and back on 25 October at 03:00 CEST (to 02:00 CET, so 02:00-02:59 happens twice).
  @vienna "Europe/Vienna"

  defp next(expression, timezone, since) do
    {:ok, cron} = Cron.parse(expression)
    Cron.next_run(cron, timezone, since)
  end

  describe "parse/1" do
    test "accepts five fields and aliases" do
      for expression <- ["0 6 * * *", "*/15 9-17 * * 1-5", " 0  6 * * * ", "@daily", "@hourly"] do
        assert {:ok, _} = Cron.parse(expression), expression
      end
    end

    test "rejects anything else" do
      assert {:error, "needs five fields: minute hour day month weekday"} = Cron.parse("0 6 * *")

      assert {:error, "needs five fields: minute hour day month weekday"} =
               Cron.parse("0 6 * * * 2027")

      assert {:error, "is not a valid cron expression"} = Cron.parse("61 * * * *")
      assert {:error, "is not a valid cron expression"} = Cron.parse("a b c d e")
      assert {:error, "@reboot is not a schedule"} = Cron.parse("@reboot")
    end
  end

  describe "next_run/3" do
    test "computes in local time and returns UTC" do
      # The spec's example: 06:00 Vienna on a summer day is 04:00 UTC.
      assert {:ok, ~U[2026-09-27 04:00:00Z]} =
               next("0 6 * * *", @vienna, ~U[2026-09-26 12:00:00Z])

      assert {:ok, ~U[2026-12-01 05:00:00Z]} =
               next("0 6 * * *", @vienna, ~U[2026-12-01 00:00:00Z])

      assert {:ok, ~U[2026-09-27 06:00:00Z]} =
               next("0 6 * * *", "Etc/UTC", ~U[2026-09-26 12:00:00Z])
    end

    test "is strictly after the given time" do
      assert {:ok, ~U[2026-09-28 04:00:00Z]} =
               next("0 6 * * *", @vienna, ~U[2026-09-27 04:00:00Z])

      assert {:ok, ~U[2026-09-27 04:00:00Z]} =
               next("0 6 * * *", @vienna, ~U[2026-09-27 03:59:59.999999Z])
    end

    test "a local time in the spring-forward gap moves to the end of the gap" do
      # 02:30 does not exist on 29 March; the gap ends at 03:00 CEST = 01:00 UTC.
      assert {:ok, ~U[2026-03-29 01:00:00Z]} =
               next("30 2 * * *", @vienna, ~U[2026-03-28 12:00:00Z])

      # The day after, 02:30 CEST exists again.
      assert {:ok, ~U[2026-03-30 00:30:00Z]} =
               next("30 2 * * *", @vienna, ~U[2026-03-29 01:00:00Z])
    end

    test "a repeated local time runs once, at its first occurrence" do
      # 02:30 on 25 October happens at 00:30 UTC (CEST) and again at 01:30 UTC (CET).
      assert {:ok, ~U[2026-10-25 00:30:00Z]} =
               next("30 2 * * *", @vienna, ~U[2026-10-24 12:00:00Z])

      assert {:ok, ~U[2026-10-26 01:30:00Z]} =
               next("30 2 * * *", @vienna, ~U[2026-10-25 00:30:00Z])
    end

    test "a frequent schedule pauses during the repeated hour" do
      # After 02:45 CEST, the local times 02:00-02:45 CET already ran; next is 03:00 CET.
      assert {:ok, ~U[2026-10-25 02:00:00Z]} =
               next("*/15 * * * *", @vienna, ~U[2026-10-25 00:45:00Z])
    end

    test "rare and impossible dates" do
      # 29 February 2028, midnight CET
      assert {:ok, ~U[2028-02-28 23:00:00Z]} =
               next("0 0 29 2 *", @vienna, ~U[2026-09-26 12:00:00Z])

      assert {:error, :never} = next("0 0 30 2 *", @vienna, ~U[2026-09-26 12:00:00Z])
    end
  end

  test "next_runs/4 returns consecutive runs" do
    {:ok, cron} = Cron.parse("0 6 * * 1-5")

    # Friday 25 September 2026, after 06:00: next are Monday, Tuesday, Wednesday.
    assert Cron.next_runs(cron, @vienna, ~U[2026-09-25 12:00:00Z], 3) == [
             ~U[2026-09-28 04:00:00Z],
             ~U[2026-09-29 04:00:00Z],
             ~U[2026-09-30 04:00:00Z]
           ]
  end
end
