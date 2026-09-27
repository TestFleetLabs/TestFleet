defmodule TestFleet.Schedules.TickWorker do
  @moduledoc """
  Runs the schedule tick every minute (`Oban.Plugins.Cron`, main spec section 28).

  Not retried (`max_attempts: 1`): the next minute's tick picks up everything that
  is still due.
  """
  use Oban.Worker, queue: :schedules, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    TestFleet.Schedules.tick(DateTime.utc_now())
    :ok
  end
end
