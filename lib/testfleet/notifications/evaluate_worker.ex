defmodule TestFleet.Notifications.EvaluateWorker do
  @moduledoc """
  Evaluates a run that just became final (Milestone 8, section 6):
  `TestFleet.Notifications.evaluate_run/1`.

  `TestFleet.Runs` inserts this job in the same transaction that makes the run
  final, so every final run is evaluated exactly when it is committed. Retrying is
  safe: deliveries are unique per channel and event.
  """
  use Oban.Worker, queue: :notifications, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) do
    {:ok, _deliveries} = TestFleet.Notifications.evaluate_run(run_id)
    :ok
  end
end
