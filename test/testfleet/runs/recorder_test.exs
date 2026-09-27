defmodule TestFleet.Runs.RecorderTest do
  use TestFleet.DataCase, async: true

  import TestFleet.RunsFixtures

  alias TestFleet.Execution.Result
  alias TestFleet.Runs
  alias TestFleet.Runs.{Recorder, Run}

  setup do
    %{run: run_fixture(status: :preparing)}
  end

  test "records the lifecycle of a run", %{run: run} do
    Runs.subscribe(run.id)
    started_at = ~U[2026-09-27 06:00:03Z]

    Recorder.handle_event(run.id, {:status, :preparing})
    Recorder.handle_event(run.id, {:image_digest, "e2e@sha256:abc"})
    Recorder.handle_event(run.id, {:container_created, "c0ffee"})

    assert %{status: :preparing, image_digest: "e2e@sha256:abc", container_id: "c0ffee"} =
             Runs.get_run!(run.id)

    Recorder.handle_event(run.id, {:running, started_at})
    assert %{status: :running, started_at: recorded} = Runs.get_run!(run.id)
    assert DateTime.compare(recorded, started_at) == :eq
    assert_receive {:run_updated, %Run{status: :running}}

    Recorder.handle_event(
      run.id,
      {:output, [%{sequence: 1, stream: :stdout, content: "tick 1", timestamp: 42}]}
    )

    assert [%{sequence: 1, content: "tick 1"}] = Runs.list_log_tail(run, 10)
    assert_receive {:run_output, [%{content: "tick 1"}]}

    Recorder.handle_event(
      run.id,
      {:finished,
       %Result{
         run_id: run.id,
         status: :failed,
         exit_code: 1,
         started_at: started_at,
         finished_at: ~U[2026-09-27 06:04:20.123456Z]
       }}
    )

    assert %{status: :failed, exit_code: 1, oom_killed: false, finished_at: finished_at} =
             Runs.get_run!(run.id)

    assert finished_at == ~U[2026-09-27 06:04:20.123456Z]
    assert_receive {:run_finished, %Run{status: :failed}}
  end

  test "late events do not change a finished run", %{run: run} do
    Recorder.handle_event(
      run.id,
      {:finished, %Result{run_id: run.id, status: :cancelled, finished_at: DateTime.utc_now()}}
    )

    Recorder.handle_event(run.id, {:running, DateTime.utc_now()})
    Recorder.handle_event(run.id, {:container_created, "late"})

    Recorder.handle_event(
      run.id,
      {:finished, %Result{run_id: run.id, status: :passed, finished_at: DateTime.utc_now()}}
    )

    assert %{status: :cancelled, container_id: nil, started_at: nil} = Runs.get_run!(run.id)
  end

  test "an error result keeps its message", %{run: run} do
    Recorder.handle_event(
      run.id,
      {:finished,
       %Result{
         run_id: run.id,
         status: :error,
         error_message: "pull access denied",
         finished_at: DateTime.utc_now()
       }}
    )

    assert %{status: :error, error_message: "pull access denied"} = Runs.get_run!(run.id)
  end
end
