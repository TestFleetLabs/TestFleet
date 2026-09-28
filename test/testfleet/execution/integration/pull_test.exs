defmodule TestFleet.Execution.Integration.PullTest do
  # Milestone 7 section 6: the pull timeout, and runs of one image sharing a pull.
  use TestFleet.DockerCase, async: true

  # A non-routable address: connecting to it hangs until Docker's own timeout.
  @unreachable_image "10.255.255.1:5000/suite:1"

  @tag :capture_log
  test "a pull that does not finish in time ends the run as error" do
    started = System.monotonic_time(:millisecond)

    {result, []} =
      run!(image: @unreachable_image, pull_policy: :always, pull_timeout_ms: 1_000)

    elapsed = System.monotonic_time(:millisecond) - started

    assert result.status == :error
    assert result.error_message == "image pull exceeded 1 s"
    assert result.started_at == nil
    assert result.container_id == nil
    # The process does not wait for the pull.
    assert elapsed < 5_000, "took #{elapsed} ms"
  end

  test "a pull within the timeout is not affected" do
    {result, _} =
      run!(
        image: registry_image(),
        registry_auth: registry_auth(),
        pull_policy: :always,
        pull_timeout_ms: 60_000,
        environment: %{"SPIKE_MODE" => "pass"}
      )

    assert result.status == :passed
  end

  test "concurrent runs of one image share the pull and all start" do
    runs =
      for _ <- 1..3 do
        start_run!(
          image: registry_image(),
          registry_auth: registry_auth(),
          pull_policy: :always,
          environment: %{"SPIKE_MODE" => "pass"}
        )
      end

    for {request, _pid} <- runs do
      assert {%{status: :passed, image_digest: "sha256:" <> _}, _} =
               await_finished(request.run_id)
    end
  end
end
