defmodule TestFleetWeb.API.RunJSON do
  @moduledoc """
  A run as the API returns it. `final` spares clients the
  list of final statuses; `tests` is null without a JUnit report.
  """
  use TestFleetWeb, :verified_routes

  alias TestFleet.Runs.Run
  alias TestFleetWeb.RunComponents

  def show(%{run: run}), do: data(run)

  def data(%Run{} = run) do
    %{
      id: run.id,
      url: url(~p"/runs/#{run}"),
      project: run.test_definition.project.slug,
      test_definition: run.test_definition.slug,
      environment: run.environment.slug,
      trigger: run.trigger,
      triggered_by: RunComponents.triggered_by(run),
      status: run.status,
      final: Run.final?(run),
      image: run.image,
      image_digest: run.image_digest,
      queued_at: run.queued_at,
      started_at: run.started_at,
      finished_at: run.finished_at,
      exit_code: run.exit_code,
      error_message: run.error_message,
      tests: tests(run),
      log_url: url(~p"/api/v1/runs/#{run}/log"),
      log_truncated: run.log_truncated,
      artifacts_url: url(~p"/api/v1/runs/#{run}/artifacts")
    }
  end

  defp tests(%Run{tests_passed: nil, tests_failed: nil, tests_skipped: nil}), do: nil

  defp tests(%Run{} = run),
    do: %{passed: run.tests_passed, failed: run.tests_failed, skipped: run.tests_skipped}
end
