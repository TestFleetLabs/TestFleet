defmodule TestFleet.Execution.Integration.BrokenStreamTest do
  # Milestone 7, section 7: a run whose connections to Docker broke is followed
  # again. The run talks to Docker through a proxy the test cuts and restores, like
  # a restarted socket proxy; the test itself talks to Docker directly.
  #
  # Not async: the Docker host is switched to the proxy for the whole application.
  use TestFleet.DockerCase, async: false

  alias TestFleet.DockerProxy
  alias TestFleet.Execution.Docker.Client

  # Lost streams and the reconnect attempts log warnings.
  @moduletag :capture_log

  setup do
    config = Application.fetch_env!(:testfleet, TestFleet.Execution.Docker)
    %URI{scheme: "tcp", host: host, port: port} = URI.parse(config[:host])

    {:ok, proxy} = DockerProxy.start_link({host, port})
    proxied = Keyword.put(config, :host, DockerProxy.host(proxy))
    Application.put_env(:testfleet, TestFleet.Execution.Docker, proxied)
    on_exit(fn -> Application.put_env(:testfleet, TestFleet.Execution.Docker, config) end)

    %{proxy: proxy, direct: "http://#{host}:#{port}/v#{Client.api_version()}"}
  end

  # Through the proxy, retrying fast; the container is removed directly when the
  # test ends, whatever state the proxy is in.
  defp start_run!(context, attrs, opts) do
    request = request(attrs)
    name = RunExecution.container_name(request.run_id)

    on_exit(fn ->
      Req.delete(context.direct <> "/containers/#{name}", params: [force: true], retry: false)
    end)

    {:ok, pid} = Execution.start(request, Keyword.merge([reconnect_interval: 100], opts))
    {request, pid}
  end

  defp direct!(context, method, path, params \\ []) do
    Req.request!(method: method, url: context.direct <> path, params: params, retry: false)
  end

  defp hanging_run!(context, opts \\ []) do
    {request, pid} = start_run!(context, [environment: %{"SPIKE_MODE" => "hang"}], opts)
    lines = await_output(request.run_id, &(&1.content == "tick 2"))
    {request, pid, lines}
  end

  test "a lost connection is followed again, without gaps or duplicates in the log", context do
    {request, _pid, before} = hanging_run!(context)

    :ok = DockerProxy.interrupt(context.proxy)
    # The suite keeps ticking while nothing can reach it.
    Process.sleep(1_500)
    :ok = DockerProxy.resume(context.proxy)

    after_resume = await_output(request.run_id, &(&1.content == "tick 6"))
    :ok = Execution.cancel(request.run_id)
    {%Result{status: :cancelled}, rest} = await_finished(request.run_id)

    lines = before ++ after_resume ++ rest
    ticks = lines |> contents() |> Enum.filter(&String.starts_with?(&1, "tick "))

    assert ticks == Enum.map(1..length(ticks), &"tick #{&1}")
    assert Enum.map(lines, & &1.sequence) == Enum.to_list(1..length(lines))
  end

  test "a suite Docker stopped meanwhile ends as error, not failed (rule 5a)", context do
    {request, _pid, _lines} = hanging_run!(context)
    name = RunExecution.container_name(request.run_id)

    :ok = DockerProxy.interrupt(context.proxy)
    %{status: 204} = direct!(context, :post, "/containers/#{name}/kill")
    :ok = DockerProxy.resume(context.proxy)

    {result, _lines} = await_finished(request.run_id)

    assert result.status == :error
    assert result.exit_code == 137

    assert result.error_message ==
             "Docker was interrupted while the suite was running (exit code 137)"

    assert %{status: 404} = direct!(context, :get, "/containers/#{name}/json")
  end

  test "a container removed meanwhile is an error", context do
    {request, _pid, _lines} = hanging_run!(context)
    name = RunExecution.container_name(request.run_id)

    :ok = DockerProxy.interrupt(context.proxy)
    %{status: 204} = direct!(context, :delete, "/containers/#{name}", force: true)
    :ok = DockerProxy.resume(context.proxy)

    assert {%Result{status: :error, error_message: "container disappeared"}, _} =
             await_finished(request.run_id)
  end

  test "without an answer in time, the process stops and leaves the run active", context do
    {request, pid, before} = hanging_run!(context, reconnect_window: 1_000)
    name = RunExecution.container_name(request.run_id)
    ref = Process.monitor(pid)

    :ok = DockerProxy.interrupt(context.proxy)

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
    refute_received {:run_event, _, {:finished, _}}
    # Nothing removed the container; the suite still runs.
    assert %{body: %{"State" => %{"Running" => true}}} =
             direct!(context, :get, "/containers/#{name}/json")

    # Once Docker is back, a reattach (the reconciler's job) picks it up.
    :ok = DockerProxy.resume(context.proxy)
    last = List.last(before ++ drain_output(request.run_id))
    attach!(request.run_id, last_log_timestamp: last.timestamp, next_sequence: last.sequence + 1)

    :ok = Execution.cancel(request.run_id)
    assert {%Result{status: :cancelled}, _} = await_finished(request.run_id)
  end

  # Output reported before the process stopped.
  defp drain_output(run_id, batches \\ []) do
    receive do
      {:run_event, ^run_id, {:output, lines}} -> drain_output(run_id, [lines | batches])
    after
      0 -> batches |> Enum.reverse() |> Enum.concat()
    end
  end
end
