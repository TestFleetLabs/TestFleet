defmodule TestFleet.Execution.RunExecution do
  @moduledoc """
  Owns one run, from image pull to container removal (main spec section 27).

  The process does not write to the database. It reports events to a
  `TestFleet.Execution.Handler` (`:handler`), called in this process, or sends them
  as `{:run_event, run_id, event}` messages to a pid (`:subscriber`):

      {:status, :preparing}
      {:image_digest, digest}
      {:container_created, container_id}
      {:running, started_at}          # the container's State.StartedAt
      {:output, [%{sequence: n, stream: :stdout | :stderr, timestamp: ns, content: line}]}
      {:finished, %TestFleet.Execution.Result{}}

  Output lines are masked (`TestFleet.Execution.Masker`) before they leave the
  process, and reported in batches: after 100 ms, 500 lines, or 1 MiB, whichever
  comes first. All output is reported before `{:finished, result}`.

  `{:finished, result}` is reported before the container is removed, so the final
  status is recorded even if TestFleet dies in between (Milestone 3, section 7). The
  process exits once the container is removed.

  Modes:

    * `:start` - pulls the image, then creates and starts `TestFleet-run-<id>`
    * `:attach` - takes over an existing container after the previous process died,
      resuming logs after `:last_log_timestamp` and numbering from `:next_sequence`

  The deadline is `State.StartedAt` of the container plus the timeout, never a fresh
  timer. The timeout and grace period are stored as container labels, so an attaching
  process can enforce the original deadline.

  The process does not remove its container when it crashes: a running suite that
  outlives its process can still be reattached (main spec section 32).
  """

  use GenServer, restart: :temporary

  require Logger

  alias TestFleet.Execution.{Collector, LineBuffer, Masker, Result, Status}
  alias TestFleet.Execution.Docker.{Command, ImageRef, LogDecoder}

  @network "TestFleet-runs"
  @artifacts_dir Collector.artifacts_dir()
  @default_stop_grace_seconds 30
  # How long to wait for the rest of the logs after the container exited.
  @drain_timeout 5_000
  # Extra time after the stop grace period before sending SIGKILL ourselves.
  @kill_margin 5_000
  # Output is reported in batches (main spec section 21, Milestone 4 section 5).
  @batch_interval 100
  @batch_max_lines 500
  @batch_max_bytes 1_048_576

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: via(Keyword.fetch!(opts, :run_id)))
  end

  def via(run_id), do: {:via, Registry, {TestFleet.Execution.Registry, run_id}}

  def container_name(run_id), do: "TestFleet-run-#{run_id}"

  def network, do: @network

  def artifacts_dir, do: @artifacts_dir

  @impl true
  def init(opts) do
    request = opts[:request]

    state = %{
      run_id: Keyword.fetch!(opts, :run_id),
      handler: opts[:handler],
      subscriber: opts[:subscriber],
      request: request,
      image: request && request.image,
      artifact_path: if(request, do: request.artifact_path, else: opts[:artifact_path]),
      max_artifact_bytes:
        if(request, do: request.max_artifact_bytes, else: opts[:max_artifact_bytes]),
      timeout_seconds: request && request.timeout_seconds,
      stop_grace_seconds: (request && request.stop_grace_seconds) || @default_stop_grace_seconds,
      phase: :preparing,
      prepare_task: nil,
      container_id: nil,
      owns_container: false,
      image_digest: nil,
      started_at: nil,
      deadline_timer: nil,
      logs: nil,
      logs_done: false,
      wait: nil,
      exited: false,
      drain_timer: nil,
      decoder: LogDecoder.new(),
      lines: LineBuffer.new(),
      masker: Masker.new(request_secrets(request)),
      sequence: opts[:next_sequence] || 1,
      batch: [],
      batch_lines: 0,
      batch_bytes: 0,
      batch_timer: nil,
      resume_after: opts[:last_log_timestamp],
      # A cancel that arrived while no process owned the run (Milestone 7, section 5)
      cancel_on_attach: Keyword.get(opts, :cancel, false),
      stopping: false,
      cancelled: false,
      timed_out: false,
      error: nil
    }

    {:ok, state, {:continue, Keyword.fetch!(opts, :mode)}}
  end

  defp request_secrets(nil), do: []

  defp request_secrets(request),
    do:
      for(
        key <- request.secret_keys,
        {:ok, value} <- [Map.fetch(request.environment, key)],
        do: value
      )

  @impl true
  def handle_continue(:start, state) do
    notify(state, {:status, :preparing})
    request = state.request
    # The pull runs in a task so that a cancel does not wait for it.
    {:noreply, %{state | prepare_task: Task.async(fn -> prepare_image(request) end)}}
  end

  def handle_continue(:attach, state) do
    case Command.inspect(container_name(state.run_id)) do
      {:ok, %{"State" => %{"Status" => "created"}} = info} ->
        state
        |> adopt(info)
        |> Map.put(:error, "container was created but never started")
        |> Map.put(:cancelled, state.cancel_on_attach)
        |> finalize()
        |> stop()

      {:ok, info} ->
        state = adopt(state, info)
        state = %{state | image_digest: resolve_digest(state.image)}
        if state.image_digest, do: notify(state, {:image_digest, state.image_digest})

        state = watch(state, info)

        # A suite that already exited keeps its own outcome; a running one is stopped.
        state =
          if state.cancel_on_attach and info["State"]["Running"],
            do: begin_stop(%{state | cancelled: true}),
            else: state

        maybe_complete(state)

      {:error, %{status: 404}} ->
        stop(finalize(%{state | error: "container disappeared"}))

      {:error, error} ->
        stop(finalize(%{state | error: error.message}))
    end
  end

  @impl true
  def handle_call(:cancel, _from, %{phase: :preparing} = state) do
    if state.prepare_task, do: Task.shutdown(state.prepare_task, :brutal_kill)
    {:stop, :normal, :ok, finalize(%{state | prepare_task: nil, cancelled: true})}
  end

  def handle_call(:cancel, _from, %{stopping: true} = state), do: {:reply, :ok, state}
  def handle_call(:cancel, _from, %{exited: true} = state), do: {:reply, :ok, state}

  def handle_call(:cancel, _from, state) do
    {:reply, :ok, begin_stop(%{state | cancelled: true})}
  end

  @impl true
  def handle_info({ref, result}, %{prepare_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | prepare_task: nil}

    case result do
      {:ok, digest} ->
        if digest, do: notify(state, {:image_digest, digest})
        create_and_start(%{state | image_digest: digest})

      {:error, message} ->
        stop(finalize(%{state | error: message}))
    end
  end

  def handle_info(:deadline, state) do
    if state.exited or state.stopping do
      {:noreply, state}
    else
      {:noreply, begin_stop(%{state | timed_out: true})}
    end
  end

  # A timer of an earlier batch may fire after that batch was flushed for its size.
  def handle_info({:flush_batch, timer}, %{batch_timer: {timer, _ref}} = state),
    do: {:noreply, flush_batch(state)}

  def handle_info({:flush_batch, _stale}, state), do: {:noreply, state}

  def handle_info(:force_kill, state) do
    unless state.exited, do: Command.kill(state.container_id)
    {:noreply, state}
  end

  def handle_info(:drain_timeout, state) do
    Logger.warning("run #{state.run_id}: log stream did not end after the container exited")
    if state.logs, do: Req.cancel_async_response(state.logs)
    stop(finalize(%{state | logs_done: true}))
  end

  def handle_info(message, state) do
    case parse_stream(state, message) do
      {:logs, parsed} -> state |> handle_logs(parsed) |> maybe_complete()
      {:wait, parsed} -> state |> handle_wait(parsed) |> maybe_complete()
      :unknown -> {:noreply, state}
    end
  end

  ## Preparing

  defp prepare_image(request) do
    result =
      with :ok <- Command.ensure_network(@network),
           {:ok, ref} <- ImageRef.parse(request.image),
           :ok <- ensure_image(request, ref),
           {:ok, image} <- Command.inspect_image(request.image) do
        {:ok, ImageRef.repo_digest(ref, image["RepoDigests"] || [])}
      end

    case result do
      {:ok, digest} ->
        {:ok, digest}

      {:error, :invalid_reference} ->
        {:error, "invalid image reference #{inspect(request.image)}"}

      {:error, %{message: message}} ->
        {:error, message}
    end
  end

  defp ensure_image(request, ref) do
    case pull_policy(request, ref) do
      :always ->
        Command.pull(ref, request.registry_auth)

      :if_missing ->
        case Command.inspect_image(request.image) do
          {:ok, _} -> :ok
          {:error, %{status: 404}} -> Command.pull(ref, request.registry_auth)
          error -> error
        end

      :never ->
        :ok
    end
  end

  defp pull_policy(%{pull_policy: :auto}, ref),
    do: if(ImageRef.digest?(ref), do: :if_missing, else: :always)

  defp pull_policy(%{pull_policy: policy}, _ref), do: policy

  defp resolve_digest(image) do
    with {:ok, ref} <- ImageRef.parse(image),
         {:ok, info} <- Command.inspect_image(image) do
      ImageRef.repo_digest(ref, info["RepoDigests"] || [])
    else
      _ -> nil
    end
  end

  defp create_and_start(state) do
    name = container_name(state.run_id)

    case Command.create(name, container_spec(state)) do
      {:ok, id} ->
        state = %{state | container_id: id, owns_container: true}
        notify(state, {:container_created, id})

        with :ok <- Command.start(id),
             {:ok, info} <- Command.inspect(id) do
          state |> watch(info) |> maybe_complete()
        else
          {:error, error} -> stop(finalize(%{state | error: error.message}))
        end

      # Another execution owns this container; it must not be touched.
      {:error, %{status: 409}} ->
        stop(finalize(%{state | error: "container #{name} already exists"}))

      {:error, error} ->
        stop(finalize(%{state | error: error.message}))
    end
  end

  defp container_spec(%{request: request} = state) do
    environment =
      for {key, value} <- request.environment,
          not String.starts_with?(to_string(key), "TestFleet_"),
          do: "#{key}=#{value}"

    reserved = [
      "TestFleet_RUN_ID=#{state.run_id}",
      "TestFleet_ENVIRONMENT=#{request.environment_name}",
      "TestFleet_ARTIFACTS_DIR=#{@artifacts_dir}"
    ]

    labels =
      %{
        "TestFleet" => "true",
        "TestFleet.run_id" => to_string(state.run_id),
        "TestFleet.timeout_seconds" => to_string(request.timeout_seconds),
        "TestFleet.stop_grace_seconds" => to_string(request.stop_grace_seconds)
      }
      |> put_present("TestFleet.project_id", request.project_id && to_string(request.project_id))
      |> put_present("TestFleet.instance", request.instance_id)
      # The keys, not the values: an attaching process reads the values from the
      # container's environment.
      |> put_present(
        "TestFleet.secret_keys",
        if(request.secret_keys != [], do: Enum.join(request.secret_keys, ","))
      )

    host_config =
      %{
        "NetworkMode" => @network,
        "SecurityOpt" => ["no-new-privileges"],
        "CapDrop" => ["ALL"],
        "Privileged" => false,
        "AutoRemove" => false,
        "ShmSize" => request.shm_size
      }
      |> put_present("Memory", request.memory_limit)
      # Without this, Docker allows as much swap again, and a suite over its limit swaps instead of being OOM-killed.
      |> put_present("MemorySwap", request.memory_limit)
      |> put_present("NanoCpus", request.cpu_limit && round(request.cpu_limit * 1_000_000_000))

    %{
      "Image" => request.image,
      "Env" => environment ++ reserved,
      "Labels" => labels,
      "Tty" => false,
      "OpenStdin" => false,
      "HostConfig" => host_config
    }
    |> put_present("Cmd", if(request.command != [], do: request.command))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp adopt(state, info) do
    labels = get_in(info, ["Config", "Labels"]) || %{}

    %{
      state
      | container_id: info["Id"],
        owns_container: true,
        masker: Masker.new(container_secrets(info, labels)),
        image: get_in(info, ["Config", "Image"]),
        timeout_seconds: label_integer(labels, "TestFleet.timeout_seconds"),
        stop_grace_seconds:
          label_integer(labels, "TestFleet.stop_grace_seconds") || @default_stop_grace_seconds
    }
  end

  # The values the suite actually got, even if the variables changed since.
  defp container_secrets(info, labels) do
    keys = String.split(labels["TestFleet.secret_keys"] || "", ",", trim: true)

    env =
      for entry <- get_in(info, ["Config", "Env"]) || [],
          [key, value] <- [String.split(entry, "=", parts: 2)],
          into: %{},
          do: {key, value}

    for key <- keys, {:ok, value} <- [Map.fetch(env, key)], do: value
  end

  defp label_integer(labels, key) do
    case Integer.parse(labels[key] || "") do
      {value, ""} -> value
      _ -> nil
    end
  end

  ## Running

  defp watch(state, info) do
    {:ok, started_at, _offset} = DateTime.from_iso8601(info["State"]["StartedAt"])
    state = arm_deadline(%{state | started_at: started_at, phase: :running})
    notify(state, {:running, started_at})

    since = state.resume_after && LogDecoder.format_since(state.resume_after)

    state =
      case Command.logs(state.container_id, since: since) do
        {:ok, logs} ->
          %{state | logs: logs}

        {:error, error} ->
          Logger.warning("run #{state.run_id}: cannot stream logs: #{error.message}")
          %{state | logs_done: true}
      end

    case Command.wait(state.container_id) do
      {:ok, wait} -> %{state | wait: wait}
      {:error, error} -> %{state | exited: true, error: error.message}
    end
  end

  defp arm_deadline(%{timeout_seconds: nil} = state), do: state

  defp arm_deadline(state) do
    deadline = DateTime.add(state.started_at, state.timeout_seconds, :second)
    delay = max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)
    %{state | deadline_timer: Process.send_after(self(), :deadline, delay)}
  end

  defp begin_stop(state) do
    id = state.container_id
    grace = state.stop_grace_seconds
    # Docker's stop blocks for up to the grace period; the process must stay responsive.
    Task.start(fn -> Command.stop(id, grace) end)
    Process.send_after(self(), :force_kill, grace * 1000 + @kill_margin)
    %{state | stopping: true}
  end

  defp parse_stream(state, message) do
    with :unknown <- parse_stream(:logs, state.logs, message) do
      parse_stream(:wait, state.wait, message)
    end
  end

  defp parse_stream(_tag, nil, _message), do: :unknown

  defp parse_stream(tag, response, message) do
    case Req.parse_message(response, message) do
      :unknown -> :unknown
      parsed -> {tag, parsed}
    end
  end

  defp handle_logs(state, {:ok, chunks}),
    do: Enum.reduce(chunks, state, &handle_log_chunk(&2, &1))

  defp handle_logs(state, {:error, reason}) do
    Logger.warning("run #{state.run_id}: log stream failed: #{inspect(reason)}")
    flush_lines(%{state | logs_done: true})
  end

  defp handle_log_chunk(state, {:data, data}) do
    {frames, decoder} = LogDecoder.feed(state.decoder, data)

    {lines, buffer} =
      Enum.reduce(frames, {[], state.lines}, fn {stream, payload}, {lines, buffer} ->
        {timestamp, content} = LogDecoder.split_timestamp(payload)

        if seen?(state, timestamp) do
          {lines, buffer}
        else
          {new_lines, buffer} = LineBuffer.feed(buffer, stream, timestamp, content)
          {[new_lines | lines], buffer}
        end
      end)

    emit(%{state | decoder: decoder, lines: buffer}, lines |> Enum.reverse() |> Enum.concat())
  end

  defp handle_log_chunk(state, :done), do: flush_lines(%{state | logs_done: true})
  defp handle_log_chunk(state, _trailers), do: state

  # After reattaching, `since` may return messages the subscriber already has.
  defp seen?(%{resume_after: nil}, _timestamp), do: false
  defp seen?(_state, nil), do: false
  defp seen?(%{resume_after: resume_after}, timestamp), do: timestamp <= resume_after

  defp handle_wait(state, {:ok, chunks}) do
    if :done in chunks, do: %{state | exited: true}, else: state
  end

  defp handle_wait(state, {:error, reason}) do
    %{state | exited: true, error: "lost the wait stream: #{inspect(reason)}"}
  end

  defp flush_lines(state) do
    {lines, buffer} = LineBuffer.flush(state.lines)
    emit(%{state | lines: buffer}, lines)
  end

  # Masks and numbers complete lines, and adds them to the pending batch.
  defp emit(state, []), do: state

  defp emit(state, lines) do
    state = Enum.reduce(lines, state, &add_to_batch(&2, &1))

    if state.batch != [] and state.batch_timer == nil do
      timer = make_ref()
      ref = Process.send_after(self(), {:flush_batch, timer}, @batch_interval)
      %{state | batch_timer: {timer, ref}}
    else
      state
    end
  end

  defp add_to_batch(state, line) do
    line =
      line
      |> Map.put(:content, Masker.mask(state.masker, line.content))
      |> Map.put(:sequence, state.sequence)

    state = %{
      state
      | sequence: state.sequence + 1,
        batch: [line | state.batch],
        batch_lines: state.batch_lines + 1,
        batch_bytes: state.batch_bytes + byte_size(line.content)
    }

    if state.batch_lines >= @batch_max_lines or state.batch_bytes >= @batch_max_bytes,
      do: flush_batch(state),
      else: state
  end

  defp flush_batch(%{batch: []} = state), do: state

  defp flush_batch(state) do
    with {_timer, ref} <- state.batch_timer, do: Process.cancel_timer(ref)
    notify(state, {:output, Enum.reverse(state.batch)})
    %{state | batch: [], batch_lines: 0, batch_bytes: 0, batch_timer: nil}
  end

  defp maybe_complete(%{exited: false} = state), do: {:noreply, state}
  defp maybe_complete(%{logs_done: true} = state), do: stop(finalize(state))

  defp maybe_complete(%{drain_timer: nil} = state) do
    {:noreply, %{state | drain_timer: Process.send_after(self(), :drain_timeout, @drain_timeout)}}
  end

  defp maybe_complete(state), do: {:noreply, state}

  ## Finishing

  defp finalize(state) do
    if state.deadline_timer, do: Process.cancel_timer(state.deadline_timer)
    if state.drain_timer, do: Process.cancel_timer(state.drain_timer)
    # All output is reported before the result.
    state = state |> flush_lines() |> flush_batch()

    # TestFleet's clock only when the container cannot tell (it never started, or
    # vanished); taken before collecting, which is not test time.
    now = DateTime.utc_now()
    {facts, collection} = inspect_container(state)
    finished_at = facts[:finished_at] || now
    {status, error_message} = Status.decide(Map.put(facts, :junit, collection.junit))

    for warning <- collection.warnings,
        do: Logger.warning("run #{state.run_id}: #{warning}")

    notify(
      state,
      {:finished,
       %Result{
         run_id: state.run_id,
         status: status,
         error_message: error_message,
         exit_code: facts[:exit_code],
         oom_killed: facts[:oom_killed] || false,
         image: state.image,
         image_digest: state.image_digest,
         container_id: state.container_id,
         started_at: state.started_at,
         finished_at: finished_at,
         artifacts: collection.artifacts,
         test_results: collection.test_results,
         warnings: collection.warnings
       }}
    )

    # After reporting: a finished run with a leftover container is recoverable, a
    # removed container of a run that still looks active is not.
    if state.owns_container, do: remove_container(state)

    state
  end

  defp inspect_container(state) do
    facts = %{
      cancelled: state.cancelled,
      timed_out: state.timed_out,
      started: state.started_at != nil,
      error: state.error
    }

    if state.container_id == nil or state.started_at == nil do
      {facts, Collector.empty()}
    else
      case Command.inspect(state.container_id) do
        {:ok, %{"State" => %{"Running" => true}}} ->
          {Map.put(facts, :error, state.error || "container is still running"), collect(state)}

        {:ok, %{"State" => container_state}} ->
          # The container's own end, like `started_at` is its own start: the
          # duration is the suite's, whatever TestFleet or Docker were busy with.
          facts =
            Map.merge(facts, %{
              exit_code: container_state["ExitCode"],
              oom_killed: container_state["OOMKilled"],
              finished_at: container_finished_at(container_state["FinishedAt"])
            })

          {facts, collect(state)}

        {:error, %{status: 404}} ->
          {Map.put(facts, :container_missing, true), Collector.empty()}

        {:error, error} ->
          {Map.put(facts, :error, error.message), Collector.empty()}
      end
    end
  end

  # Docker reports "0001-01-01T00:00:00Z" for a container that has not finished.
  defp container_finished_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{year: year} = finished_at, _offset} when year > 1 -> finished_at
      _ -> nil
    end
  end

  defp container_finished_at(_value), do: nil

  defp collect(state),
    do: Collector.collect(state.container_id, state.artifact_path, state.max_artifact_bytes)

  defp remove_container(state) do
    case Command.remove(state.container_id) do
      :ok ->
        :ok

      {:error, error} ->
        Logger.warning("run #{state.run_id}: cannot remove container: #{error.message}")
    end
  end

  defp notify(%{handler: nil} = state, event),
    do: send(state.subscriber, {:run_event, state.run_id, event})

  defp notify(state, event), do: state.handler.handle_event(state.run_id, event)

  defp stop(state), do: {:stop, :normal, state}
end
