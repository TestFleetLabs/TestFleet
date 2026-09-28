defmodule TestFleet.Schedules.TickWorker do
  @moduledoc """
  Runs the schedule tick every minute (`Oban.Plugins.Cron`, main spec section 28).

  Not retried (`max_attempts: 1`): the next minute's tick picks up everything that
  is still due.

  A completed tick pings the heartbeat URL, if one is configured, in a task so the
  tick never waits for it (`TestFleet.Notifications.Heartbeat`, Milestone 8
  section 7).
  """
  use Oban.Worker, queue: :schedules, max_attempts: 1

  alias TestFleet.Notifications.Heartbeat

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    TestFleet.Schedules.tick(DateTime.utc_now())
    Task.start(&Heartbeat.ping/0)
    :ok
  end
end
