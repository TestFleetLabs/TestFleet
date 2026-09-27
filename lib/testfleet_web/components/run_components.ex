defmodule TestFleetWeb.RunComponents do
  @moduledoc """
  Building blocks for showing runs: the status badge, durations, and list rows.
  """
  use Phoenix.Component
  use Gettext, backend: TestFleetWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: TestFleetWeb.Endpoint,
    router: TestFleetWeb.Router,
    statics: TestFleetWeb.static_paths()

  import TestFleetWeb.AppComponents, only: [local_time: 1]
  import TestFleetWeb.CoreComponents, only: [icon: 1]

  alias TestFleet.Runs.Run
  alias TestFleet.Schedules.Timezones

  @doc """
  Renders a run's status. `failed` (tests failed) and `error` (infrastructure
  failed) differ in colour and icon; active runs pulse.
  """
  attr :status, :atom, required: true
  attr :id, :string, default: nil
  attr :size, :atom, default: :sm, values: [:sm, :lg]

  def run_status(assigns) do
    ~H"""
    <span
      id={@id}
      data-status={@status}
      class={[
        "inline-flex shrink-0 items-center gap-1.5 rounded-full font-medium whitespace-nowrap",
        if(@size == :lg, do: "px-3 py-1 text-sm", else: "px-2 py-0.5 text-xs"),
        status_classes(@status)
      ]}
    >
      <span :if={@status in Run.active_statuses()} class="relative flex size-2">
        <span class="absolute inline-flex size-full animate-ping rounded-full bg-current opacity-60"></span>
        <span class="relative inline-flex size-2 rounded-full bg-current"></span>
      </span>
      <.icon
        :if={@status not in Run.active_statuses()}
        name={status_icon(@status)}
        class={if(@size == :lg, do: "size-4", else: "size-3.5")}
      />
      {status_label(@status)}
    </span>
    """
  end

  defp status_classes(:queued), do: "bg-base-200 text-base-content/70"
  defp status_classes(:preparing), do: "bg-info/10 text-info"
  defp status_classes(:running), do: "bg-info/15 text-info"
  defp status_classes(:passed), do: "bg-success/15 text-success"
  defp status_classes(:failed), do: "bg-error/10 text-error"
  defp status_classes(:timeout), do: "bg-warning/15 text-warning"
  defp status_classes(:cancelled), do: "bg-base-200 text-base-content/60"
  # An infrastructure failure, not a test result: deliberately unlike `failed`.
  defp status_classes(:error), do: "bg-neutral text-neutral-content"

  defp status_icon(:queued), do: "hero-clock-mini"
  defp status_icon(:passed), do: "hero-check-circle-mini"
  defp status_icon(:failed), do: "hero-x-circle-mini"
  defp status_icon(:timeout), do: "hero-clock-mini"
  defp status_icon(:cancelled), do: "hero-no-symbol-mini"
  defp status_icon(:error), do: "hero-exclamation-triangle-mini"

  @doc "The display name of a status."
  def status_label(:queued), do: gettext("Queued")
  def status_label(:preparing), do: gettext("Preparing")
  def status_label(:running), do: gettext("Running")
  def status_label(:passed), do: gettext("Passed")
  def status_label(:failed), do: gettext("Failed")
  def status_label(:timeout), do: gettext("Timeout")
  def status_label(:cancelled), do: gettext("Cancelled")
  def status_label(:error), do: gettext("Error")

  @doc "The display name of a trigger."
  def trigger_label(:manual), do: gettext("Manual")
  def trigger_label(:schedule), do: gettext("Schedule")
  def trigger_label(:api), do: gettext("API")

  @doc """
  How long a run has been running: from `started_at` to `finished_at`, or to `now`
  while it is active. `nil` before it started.
  """
  def run_duration(%Run{started_at: nil}, _now), do: nil

  def run_duration(%Run{started_at: started_at, finished_at: finished_at}, now) do
    max(DateTime.diff(finished_at || now, started_at, :second), 0)
  end

  @doc "Formats seconds as `12s`, `4m 17s`, or `1h 02m`."
  def format_duration(nil), do: "–"
  def format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  def format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{pad(rem(seconds, 60))}s"

  def format_duration(seconds),
    do: "#{div(seconds, 3600)}h #{pad(div(rem(seconds, 3600), 60))}m"

  defp pad(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc """
  Renders a run as a list row linking to the run page. Expects the run with its
  test definition (and project) and environment preloaded.

  `context` leaves out what the surrounding page already says: `:test_definition`
  hides the test definition, `:project` the project.
  """
  attr :id, :string, required: true
  attr :run, Run, required: true
  attr :context, :atom, default: nil, values: [nil, :project, :test_definition]

  def run_row(assigns) do
    ~H"""
    <li id={@id}>
      <.link
        navigate={~p"/runs/#{@run.id}"}
        class="group flex items-center gap-4 px-5 py-3 transition-colors duration-150 hover:bg-base-200/40"
      >
        <.run_status status={@run.status} />
        <div class="min-w-0 flex-1">
          <p class="flex items-center gap-2 truncate text-sm font-medium">
            <span class="text-base-content/50 tabular-nums">#{@run.id}</span>
            <span :if={@context != :test_definition} class="truncate">
              {@run.test_definition.name}
            </span>
            <span :if={@context == :test_definition} class="truncate">
              {@run.environment.name}
            </span>
          </p>
          <p class="truncate text-xs text-base-content/60">
            <span :if={@context == nil}>{@run.test_definition.project.name} · </span>
            <span :if={@context != :test_definition}>{@run.environment.name} · </span>
            {trigger_label(@run.trigger)}
          </p>
        </div>
        <div class="hidden shrink-0 text-right text-xs text-base-content/60 sm:block">
          <.local_time at={@run.started_at || @run.queued_at} timezone={Timezones.default()} />
          <p :if={Run.final?(@run)} class="tabular-nums">
            {format_duration(run_duration(@run, @run.finished_at))}
          </p>
        </div>
        <.icon
          name="hero-chevron-right-mini"
          class="size-4 shrink-0 text-base-content/30 transition group-hover:translate-x-0.5 group-hover:text-primary"
        />
      </.link>
    </li>
    """
  end
end
