defmodule TestFleet.Artifacts.CleanupWorker do
  @moduledoc """
  Expires old artifacts and logs once per hour (`Oban.Plugins.Cron`, Milestone 6
  section 8), with `TestFleet.Retention`.

  Not retried (`max_attempts: 1`): the next hour picks up everything still due.
  """
  use Oban.Worker, queue: :cleanup, max_attempts: 1

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    %{artifacts: artifacts, logs: logs} = TestFleet.Retention.run()

    if artifacts + logs > 0 do
      Logger.info("Retention expired the artifacts of #{artifacts} and the logs of #{logs} runs")
    end

    :ok
  end
end
