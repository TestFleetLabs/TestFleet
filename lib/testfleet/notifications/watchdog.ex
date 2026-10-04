defmodule TestFleet.Notifications.Watchdog do
  @moduledoc """
  Reports TestFleet's own problems. A GenServer, not an
  Oban job: it must notice when Oban's cron is stuck.

  Once per `:interval` (default 1 min) it checks:

    * **Docker:** unreachable for `:docker_alert_after` (5 min) →
      `system.docker_unreachable`; reachable again after that alert →
      `system.docker_recovered`. Short outages stay quiet.
    * **Scheduling:** enabled schedules more than `:schedule_alert_after` (10 min)
      overdue → one `system.scheduling_stalled` listing them; none overdue any more
      after that alert → `system.scheduling_recovered`.

  Each episode, from its alert to its recovery, alerts once. The episode state
  lives in this process: after a restart during an outage, it alerts again.

  Options (default from `config :testfleet, #{inspect(__MODULE__)}`): `:interval`,
  `:docker_alert_after`, `:schedule_alert_after` (milliseconds), `:enabled`
  (`false` makes `start_link/1` return `:ignore`), and for tests `:docker_status`
  and `:now` (zero-arity functions).
  """
  use GenServer

  require Logger

  alias TestFleet.{Execution, Notifications, Schedules}

  @defaults [
    interval: 60_000,
    docker_alert_after: :timer.minutes(5),
    schedule_alert_after: :timer.minutes(10),
    enabled: true
  ]

  # Names listed in a stalled-scheduling message.
  @listed_schedules 10

  def start_link(opts \\ []) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:testfleet, __MODULE__, []))
      |> Keyword.merge(opts)

    if config[:enabled],
      do: GenServer.start_link(__MODULE__, config, name: Keyword.get(config, :name, __MODULE__)),
      else: :ignore
  end

  @doc "Checks now and waits for it."
  def check(server \\ __MODULE__), do: GenServer.call(server, :check)

  @impl true
  def init(config) do
    state =
      config
      |> Map.new()
      |> Map.put_new(:docker_status, &Execution.docker_status/0)
      |> Map.put_new(:now, &DateTime.utc_now/0)
      # The start of the episode alerted about, or nil.
      |> Map.merge(%{docker_alerted: nil, scheduling_alerted: nil})

    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state), do: {:reply, :ok, run_checks(state)}

  @impl true
  def handle_info(:check, state) do
    state = run_checks(state)
    schedule(state.interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :check, interval)

  # A check that fails (the database is down) keeps the state, so the next one
  # tries again.
  defp run_checks(state) do
    now = state.now.()

    Enum.reduce([&check_docker/2, &check_scheduling/2], state, fn check, state ->
      try do
        check.(state, now)
      rescue
        exception ->
          Logger.error("watchdog check failed: " <> Exception.message(exception))
          state
      end
    end)
  end

  ## Docker

  defp check_docker(state, now) do
    status = state.docker_status.()
    alerted = state.docker_alerted

    cond do
      status.reachable and alerted != nil ->
        recovered_docker(state, now)

      status.reachable ->
        state

      alerted != nil and DateTime.compare(alerted, status.since || alerted) == :eq ->
        state

      # Docker came back and went away again between two checks: that outage is
      # over, and this one starts its own.
      alerted != nil ->
        state |> recovered_docker(status.since) |> check_docker(now)

      DateTime.diff(now, status.since || now, :millisecond) >= state.docker_alert_after ->
        since = status.since || now

        notify("system.docker_unreachable", key("system.docker_unreachable", since), %{
          "since" => DateTime.to_iso8601(since),
          "message" => status.message
        })

        %{state | docker_alerted: since}

      true ->
        state
    end
  end

  defp recovered_docker(state, recovered_at) do
    since = state.docker_alerted

    notify("system.docker_recovered", key("system.docker_recovered", since), %{
      "since" => DateTime.to_iso8601(since),
      "recovered_at" => DateTime.to_iso8601(recovered_at)
    })

    %{state | docker_alerted: nil}
  end

  ## Scheduling

  defp check_scheduling(state, now) do
    cutoff = DateTime.add(now, -state.schedule_alert_after, :millisecond)
    overdue = Schedules.list_overdue(cutoff)
    alerted = state.scheduling_alerted

    cond do
      overdue != [] and alerted == nil ->
        notify("system.scheduling_stalled", key("system.scheduling_stalled", now), %{
          "count" => length(overdue),
          "schedules" => overdue |> Enum.take(@listed_schedules) |> Enum.map(&schedule_name/1),
          "oldest_due" => DateTime.to_iso8601(hd(overdue).next_run_at)
        })

        %{state | scheduling_alerted: now}

      overdue == [] and alerted != nil ->
        notify("system.scheduling_recovered", key("system.scheduling_recovered", alerted), %{
          "since" => DateTime.to_iso8601(alerted),
          "recovered_at" => DateTime.to_iso8601(now)
        })

        %{state | scheduling_alerted: nil}

      true ->
        state
    end
  end

  defp schedule_name(schedule) do
    test_definition = schedule.test_definition

    "#{test_definition.name} on #{schedule.environment.name} (#{test_definition.project.name})"
  end

  ## Delivering

  defp key(event, %DateTime{} = episode), do: "#{event}:#{DateTime.to_unix(episode)}"

  defp notify(event, dedupe_key, data) do
    level = if String.ends_with?(event, "_recovered"), do: :info, else: :warning
    Logger.log(level, "#{event}: #{inspect(data)}")
    {:ok, _deliveries} = Notifications.notify_system(event, dedupe_key, data)
  end
end
