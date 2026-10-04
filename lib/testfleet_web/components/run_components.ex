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
        if(@size == :lg, do: "pl-2 pr-3 py-1 text-sm", else: "pl-1 pr-2 py-0.5 text-xs"),
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

  @doc "The email of the user who started the run, or nil (scheduled runs, not preloaded)."
  def triggered_by(%{triggered_by_user: %TestFleet.Accounts.User{email: email}}), do: email
  def triggered_by(_run), do: nil

  @doc "The name of the token that started an API run, or nil."
  def triggered_via(%{trigger: :api, api_token: %TestFleet.Accounts.APIToken{name: name}}),
    do: name

  def triggered_via(%{trigger: :api, api_token: nil}), do: gettext("a revoked token")
  def triggered_via(_run), do: nil

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

  # CSI sequences (colours, cursor movement) and OSC sequences (titles, links).
  @ansi ~r/\e\[[0-?]*[ -\/]*[@-~]|\e\][^\a\e]*(?:\a|\e\\)|\e[@-Z\\-_]/

  @doc """
  Renders one log line: its number, and its content with `[MASKED]` shown as a
  badge. ANSI escape sequences are stripped for display; the stored line keeps them.
  """
  attr :id, :string, required: true
  attr :line, :map, required: true

  def log_line(assigns) do
    assigns = assign(assigns, :segments, log_segments(assigns.line.content))

    ~H"""
    <li
      id={@id}
      data-stream={@line.stream}
      class={[
        "group grid grid-cols-[4.5rem_minmax(0,1fr)] px-2 hover:bg-white/[0.03]",
        @line.stream == :stderr && "bg-amber-400/[0.06] text-amber-200/90"
      ]}
    >
      <span class="select-none pr-4 text-right tabular-nums text-zinc-600 group-hover:text-zinc-400">
        {@line.sequence}
      </span>
      <%!-- phx-no-format: whitespace inside is visible (pre-wrap) --%>
      <span class="whitespace-pre-wrap break-all" phx-no-format><%= for segment <- @segments do %><%= if segment == :masked do %><span class="mx-px rounded bg-zinc-700/80 px-1 text-[0.7rem] font-semibold tracking-wide text-zinc-300">MASKED</span><% else %>{segment}<% end %><% end %></span>
    </li>
    """
  end

  @doc "Splits displayed content into text and `:masked` segments."
  def log_segments(content) do
    content
    |> String.replace(@ansi, "")
    |> String.split(TestFleet.Execution.Masker.mask_text())
    |> Enum.intersperse(:masked)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Renders a run's JUnit counts compactly, e.g. "42 ✓ 2 ✗ 1 skipped". Nothing
  for a run without JUnit.
  """
  attr :run, Run, required: true
  attr :id, :string, default: nil

  def test_counts(assigns) do
    ~H"""
    <span
      :if={@run.tests_passed != nil}
      id={@id}
      class="inline-flex items-center gap-2 tabular-nums"
      title={
        gettext("%{passed} passed · %{failed} failed · %{skipped} skipped",
          passed: @run.tests_passed,
          failed: @run.tests_failed,
          skipped: @run.tests_skipped
        )
      }
    >
      <span class="inline-flex items-center gap-0.5 text-success" data-count="passed">
        {@run.tests_passed}<.icon name="hero-check-mini" class="size-3.5" />
      </span>
      <span
        :if={@run.tests_failed > 0}
        class="inline-flex items-center gap-0.5 text-error"
        data-count="failed"
      >
        {@run.tests_failed}<.icon name="hero-x-mark-mini" class="size-3.5" />
      </span>
      <span
        :if={@run.tests_skipped > 0}
        class="inline-flex items-center gap-0.5 text-base-content/50"
        data-count="skipped"
      >
        {@run.tests_skipped}<.icon name="hero-minus-mini" class="size-3.5" />
      </span>
    </span>
    """
  end

  @doc """
  Renders one test result. Failed and errored tests show their message, and the
  details (stack trace) in a `<details>` element.
  """
  attr :id, :string, required: true
  attr :result, TestFleet.Results.TestResult, required: true

  def test_result_row(assigns) do
    ~H"""
    <li id={@id} data-status={@result.status} class="px-5 py-3">
      <div class="flex items-start gap-3">
        <.icon
          name={test_status_icon(@result.status)}
          class={["mt-0.5 size-4 shrink-0", test_status_class(@result.status)]}
        />
        <div class="min-w-0 flex-1">
          <div class="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
            <p class="min-w-0 text-sm font-medium break-words">{@result.name}</p>
            <span
              :if={@result.duration_ms}
              class="shrink-0 text-xs text-base-content/50 tabular-nums"
            >
              {format_ms(@result.duration_ms)}
            </span>
          </div>
          <p
            :if={@result.suite != "" or @result.classname != ""}
            class="mt-0.5 truncate text-xs text-base-content/60"
          >
            {[@result.suite, @result.classname] |> Enum.reject(&(&1 == "")) |> Enum.join(" › ")}
          </p>
          <p
            :if={@result.status == :error}
            class="mt-1.5 text-xs font-medium text-base-content/70"
          >
            {gettext("Error, not an assertion failure")}
          </p>
          <%!-- phx-no-format: whitespace inside is visible (pre-wrap) --%>
          <p
            :if={@result.failure_message}
            data-failure-message
            class={[
              "mt-1.5 font-mono text-xs break-words whitespace-pre-wrap",
              test_status_class(@result.status)
            ]}
            phx-no-format
          >{@result.failure_message}</p>
          <details :if={@result.failure_details} class="group mt-2">
            <summary class="inline-flex cursor-pointer list-none items-center gap-1 text-xs font-medium text-base-content/60 transition-colors hover:text-base-content">
              <.icon
                name="hero-chevron-right-mini"
                class="size-4 transition-transform group-open:rotate-90"
              />
              {gettext("Details")}
            </summary>
            <pre class="mt-2 max-h-96 overflow-auto rounded-lg bg-zinc-950 p-3 font-mono text-xs leading-5 text-zinc-200">{@result.failure_details}</pre>
          </details>
        </div>
      </div>
    </li>
    """
  end

  defp test_status_icon(:passed), do: "hero-check-circle-mini"
  defp test_status_icon(:failed), do: "hero-x-circle-mini"
  defp test_status_icon(:error), do: "hero-exclamation-triangle-mini"
  defp test_status_icon(:skipped), do: "hero-minus-circle-mini"

  defp test_status_class(:passed), do: "text-success"
  defp test_status_class(:failed), do: "text-error"
  # Like the run statuses: an error is not a failed assertion.
  defp test_status_class(:error), do: "text-warning"
  defp test_status_class(:skipped), do: "text-base-content/40"

  @doc "Formats milliseconds as `85 ms`, `12.3s`, or `4m 17s`."
  def format_ms(ms) when ms < 1_000, do: "#{ms} ms"
  def format_ms(ms) when ms < 60_000, do: "#{Float.round(ms / 1_000, 1)}s"
  def format_ms(ms), do: format_duration(div(ms, 1_000))

  @doc "Formats a file size, e.g. `812 B`, `20 KiB`, or `1.4 MiB`."
  def format_size(bytes) when bytes < 1_024, do: "#{bytes} B"
  def format_size(bytes) when bytes < 1_024 * 1_024, do: "#{round_unit(bytes / 1_024)} KiB"

  def format_size(bytes) when bytes < 1_024 * 1_024 * 1_024,
    do: "#{round_unit(bytes / (1_024 * 1_024))} MiB"

  def format_size(bytes), do: "#{round_unit(bytes / (1_024 * 1_024 * 1_024))} GiB"

  defp round_unit(value) when value >= 10, do: round(value)
  defp round_unit(value), do: Float.round(value, 1)

  @doc """
  The URL of a run's artifact. Each segment of the name is encoded on its own, so
  the directory structure stays in the URL and relative links in a report work.
  """
  def artifact_url(run_id, name) do
    path =
      name
      |> String.split("/")
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    ~p"/runs/#{run_id}/artifacts" <> "/" <> path
  end

  @image_types ~w(image/png image/jpeg image/gif image/webp)
  @video_types ~w(video/webm video/mp4)

  @doc "`:image`, `:video`, `:html`, or `:file`: how the artifacts panel shows it."
  def artifact_kind(%{content_type: type}) when type in @image_types, do: :image
  def artifact_kind(%{content_type: type}) when type in @video_types, do: :video
  def artifact_kind(%{content_type: "text/html"}), do: :html
  def artifact_kind(_artifact), do: :file

  @doc """
  Turns a run's artifacts into the rows of a tree: a `:dir` row before the
  contents of each directory, directories before files at each level. Each row has
  a `depth`; a directory with an `index.html` has it as `index`.
  """
  def artifact_tree(artifacts) do
    by_name = Map.new(artifacts, &{&1.name, &1})

    {rows, _open} =
      artifacts
      |> Enum.sort_by(&tree_key(&1.name))
      |> Enum.flat_map_reduce([], fn artifact, open ->
        dirs = artifact.name |> String.split("/") |> Enum.drop(-1)
        common = common_length(open, dirs)

        dir_rows =
          for depth <- common..(length(dirs) - 1)//1 do
            path = dirs |> Enum.take(depth + 1) |> Enum.join("/")

            %{
              kind: :dir,
              name: Enum.at(dirs, depth),
              path: path,
              depth: depth,
              index: by_name[path <> "/index.html"]
            }
          end

        file_row = %{
          kind: :file,
          name: Path.basename(artifact.name),
          artifact: artifact,
          depth: length(dirs)
        }

        {dir_rows ++ [file_row], dirs}
      end)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> Map.put(row, :id, "artifact-row-#{index}") end)
  end

  defp tree_key(name) do
    {dirs, [file]} = name |> String.split("/") |> Enum.split(-1)
    Enum.map(dirs, &{0, &1}) ++ [{1, file}]
  end

  defp common_length([same | a], [same | b]), do: 1 + common_length(a, b)
  defp common_length(_a, _b), do: 0

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
          <p class="flex items-center gap-3 text-xs text-base-content/60">
            <span class="truncate">
              <span :if={@context == nil}>{@run.test_definition.project.name} · </span>
              <span :if={@context != :test_definition}>{@run.environment.name} · </span>
              {trigger_label(@run.trigger)}
              <span :if={triggered_by(@run)}>· {triggered_by(@run)}</span>
            </span>
            <.test_counts id={"#{@id}-tests"} run={@run} />
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
