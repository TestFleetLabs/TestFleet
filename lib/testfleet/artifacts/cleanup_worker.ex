defmodule TestFleet.Artifacts.CleanupWorker do
  @moduledoc """
  Cleans up once per hour (`Oban.Plugins.Cron`), in four independent steps:

    1. `TestFleet.Retention`: expires old artifacts and logs
    2. `TestFleet.ImageCleanup`: removes images no run needs any more
    3. `TestFleet.Artifacts.Orphans`: deletes artifact files no run accounts for
    4. Notification deliveries older than 90 days are deleted

  A step that fails is logged and does not stop the others. Not retried
  (`max_attempts: 1`): the next hour picks up everything still due.
  """
  use Oban.Worker, queue: :cleanup, max_attempts: 1

  require Logger

  alias TestFleet.Artifacts.Orphans
  alias TestFleet.{ImageCleanup, Notifications, Retention}

  @delivery_retention_days 90

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    step("retention", fn ->
      %{artifacts: artifacts, logs: logs} = Retention.run()

      if artifacts + logs > 0 do
        Logger.info(
          "Retention expired the artifacts of #{artifacts} and the logs of #{logs} runs"
        )
      end
    end)

    step("image cleanup", fn ->
      case ImageCleanup.run() do
        {:ok, %{removed: removed, in_use: in_use}} when removed + in_use > 0 ->
          Logger.info("Image cleanup removed #{removed} images; #{in_use} still in use")

        {:ok, _counts} ->
          :ok

        {:error, error} ->
          Logger.warning("Image cleanup skipped, Docker is not reachable: #{error.message}")
      end
    end)

    step("orphaned artifact cleanup", &Orphans.run/0)

    step("delivery cleanup", fn ->
      cutoff = DateTime.add(DateTime.utc_now(), -@delivery_retention_days, :day)
      count = Notifications.prune_deliveries(cutoff)
      if count > 0, do: Logger.info("Deleted #{count} notification deliveries")
    end)

    :ok
  end

  defp step(name, fun) do
    fun.()
  rescue
    exception ->
      Logger.error(
        "Cleanup step #{name} failed: " <> Exception.format(:error, exception, __STACKTRACE__)
      )
  end
end
