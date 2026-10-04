defmodule TestFleet.Notifications.Message do
  @moduledoc """
  What a notification says, independent of where it goes.
  `TestFleet.Notifications.Format` turns it into an email, Slack blocks, an Adaptive
  Card, or webhook JSON.

    * `title` - one line, e.g. "Customer Portal E2E is failing on production"
    * `summary` - one or two sentences
    * `facts` - `{label, value}` pairs
    * `link` - `%{label: ..., url: ...}`, absolute, or `nil`
    * `payload` - the event-specific part of the webhook JSON

  Messages never carry secrets, environment variables, log output, or test failure
  messages: channels are read by more people than the run page.
  """

  use Phoenix.VerifiedRoutes, endpoint: TestFleetWeb.Endpoint, router: TestFleetWeb.Router

  alias TestFleet.Notifications.Channel

  @enforce_keys [:event, :title]
  defstruct [:event, :title, :summary, :link, facts: [], payload: %{}, occurred_at: nil]

  @type t :: %__MODULE__{
          event: String.t(),
          title: String.t(),
          summary: String.t() | nil,
          facts: [{String.t(), String.t()}],
          link: %{label: String.t(), url: String.t()} | nil,
          payload: map(),
          occurred_at: DateTime.t() | nil
        }

  @doc """
  The message of a run event. `run` has its environment
  and its test definition with the project; `data` is the delivery's (the previous
  status and run id); `failures` names up to three failed tests and counts all.
  """
  def run_event(event, run, data, failures \\ %{names: [], count: 0}) do
    test_definition = run.test_definition
    project = test_definition.project
    environment = run.environment
    duration_ms = duration_ms(run)

    facts =
      [
        {"Project", project.name},
        {"Environment", environment.name},
        {"Trigger", trigger_label(run.trigger)},
        duration_ms && {"Duration", format_duration(duration_ms)},
        run.tests_failed != nil && {"Tests", test_counts(run)},
        (event == "run.failing" and failures.names != []) &&
          {"First failures", failure_list(failures)},
        data["previous_status"] &&
          {"Previous run", "#{data["previous_status"]} (##{data["previous_run_id"]})"}
      ]
      |> Enum.filter(& &1)

    %__MODULE__{
      event: event,
      title: run_title(event, run, test_definition.name, environment.name),
      summary: run_summary(event, run, duration_ms),
      facts: facts,
      link: %{label: "Open run ##{run.id}", url: url(~p"/runs/#{run.id}")},
      payload: %{
        "run" => %{
          "id" => run.id,
          "status" => to_string(run.status),
          "trigger" => to_string(run.trigger),
          "url" => url(~p"/runs/#{run.id}"),
          "started_at" => run.started_at && DateTime.to_iso8601(run.started_at),
          "finished_at" => run.finished_at && DateTime.to_iso8601(run.finished_at),
          "duration_ms" => duration_ms,
          "exit_code" => run.exit_code,
          "error_message" => run.error_message,
          # nil without JUnit
          "tests" =>
            if(run.tests_failed != nil,
              do: %{
                "passed" => run.tests_passed,
                "failed" => run.tests_failed,
                "skipped" => run.tests_skipped
              }
            ),
          "failed_tests" => if(event == "run.failing", do: failures.names, else: [])
        },
        "previous_status" => data["previous_status"],
        "previous_run_id" => data["previous_run_id"],
        "test_definition" => %{
          "id" => test_definition.id,
          "name" => test_definition.name,
          "slug" => test_definition.slug
        },
        "project" => %{"id" => project.id, "name" => project.name, "slug" => project.slug},
        "environment" => %{"id" => environment.id, "name" => environment.name}
      },
      occurred_at: DateTime.truncate(run.finished_at || DateTime.utc_now(), :second)
    }
  end

  defp run_title("run.failing", %{status: :timeout}, name, environment),
    do: "#{name} timed out on #{environment}"

  defp run_title("run.failing", _run, name, environment),
    do: "#{name} is failing on #{environment}"

  defp run_title("run.recovered", _run, name, environment),
    do: "#{name} recovered on #{environment}"

  defp run_title("run.error", _run, name, environment),
    do: "#{name} could not run on #{environment}"

  defp run_summary("run.failing", %{status: :timeout}, duration_ms),
    do: "It did not finish in time and was stopped#{after_duration(duration_ms)}."

  defp run_summary("run.failing", %{tests_failed: failed} = run, _duration_ms)
       when is_integer(failed) and failed > 0,
       do: "#{failed} of #{total_tests(run)} tests failed."

  defp run_summary("run.failing", %{exit_code: code}, _duration_ms) when is_integer(code),
    do: "The suite exited with code #{code}."

  defp run_summary("run.failing", _run, _duration_ms), do: "The suite failed."

  defp run_summary("run.recovered", %{tests_passed: passed}, _duration_ms)
       when is_integer(passed) and passed > 0,
       do: "All #{passed} tests passed."

  defp run_summary("run.recovered", _run, _duration_ms), do: "The suite passed."

  # TestFleet's own message: it names the infrastructure problem, not a test.
  defp run_summary("run.error", run, _duration_ms),
    do: run.error_message || "The run ended with an infrastructure error."

  defp after_duration(nil), do: ""
  defp after_duration(ms), do: " after #{format_duration(ms)}"

  defp trigger_label(:manual), do: "Manual"
  defp trigger_label(:schedule), do: "Scheduled"
  defp trigger_label(:api), do: "API"

  defp total_tests(run),
    do: (run.tests_passed || 0) + (run.tests_failed || 0) + (run.tests_skipped || 0)

  defp test_counts(run) do
    ["#{run.tests_passed || 0} passed", "#{run.tests_failed} failed"]
    |> Kernel.++(if (run.tests_skipped || 0) > 0, do: ["#{run.tests_skipped} skipped"], else: [])
    |> Enum.join(", ")
  end

  defp failure_list(%{names: names, count: count}) do
    more = count - length(names)
    Enum.join(names, ", ") <> if(more > 0, do: " and #{more} more", else: "")
  end

  defp duration_ms(%{started_at: %DateTime{} = started, finished_at: %DateTime{} = finished}),
    do: max(DateTime.diff(finished, started, :millisecond), 0)

  defp duration_ms(_run), do: nil

  @doc "A duration for people, e.g. `4 min 12 s`, `1 h 3 min`, or `850 ms`."
  def format_duration(ms) when ms < 1_000, do: "#{ms} ms"
  def format_duration(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s"

  def format_duration(ms) when ms < 3_600_000 do
    seconds = div(rem(ms, 60_000), 1_000)
    "#{div(ms, 60_000)} min" <> if(seconds > 0, do: " #{seconds} s", else: "")
  end

  def format_duration(ms) do
    minutes = div(rem(ms, 3_600_000), 60_000)
    "#{div(ms, 3_600_000)} h" <> if(minutes > 0, do: " #{minutes} min", else: "")
  end

  @doc """
  The message of a system event, from the data the
  watchdog stored with the delivery. Times are shown in the default timezone.
  """
  def system_event(event, data, occurred_at) do
    {title, summary, facts} = system_text(event, data)

    %__MODULE__{
      event: event,
      title: title,
      summary: summary,
      facts: facts,
      link: %{label: "Open the dashboard", url: url(~p"/")},
      payload: %{"system" => data},
      occurred_at: DateTime.truncate(occurred_at, :second)
    }
  end

  defp system_text("system.docker_unreachable", data) do
    {"Docker is not reachable",
     "TestFleet cannot reach Docker since #{local_time(data["since"])}. Queued runs wait until it is back.",
     Enum.filter([data["message"] && {"Error", data["message"]}], & &1)}
  end

  defp system_text("system.docker_recovered", data) do
    {"Docker is reachable again",
     "Docker was not reachable from #{local_time(data["since"])} to #{local_time(data["recovered_at"])}. Queued runs start again.",
     []}
  end

  defp system_text("system.scheduling_stalled", data) do
    count = data["count"] || length(data["schedules"] || [])
    names = data["schedules"] || []
    more = count - length(names)

    {"Scheduling is stalled",
     "#{count} #{if count == 1, do: "schedule is", else: "schedules are"} more than 10 minutes overdue: TestFleet is not creating their runs.",
     [
       {"Overdue", Enum.join(names, ", ") <> if(more > 0, do: " and #{more} more", else: "")},
       {"Due since", local_time(data["oldest_due"])}
     ]}
  end

  defp system_text("system.scheduling_recovered", data) do
    {"Scheduling runs again",
     "No schedule is overdue any more (stalled since #{local_time(data["since"])}).", []}
  end

  defp local_time(nil), do: "unknown"

  defp local_time(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, datetime, _offset} ->
        datetime
        |> DateTime.shift_zone!(TestFleet.Schedules.Timezones.default())
        |> Calendar.strftime("%Y-%m-%d %H:%M %Z")

      {:error, _} ->
        iso8601
    end
  end

  @doc "The message of \"Send test\"."
  def test(%Channel{} = channel, now \\ DateTime.utc_now()) do
    %__MODULE__{
      event: "test",
      title: "Test notification from TestFleet",
      summary: "The channel #{channel.name} is set up correctly.",
      facts: [{"Channel", channel.name}],
      link: %{label: "Open notifications", url: url(~p"/notifications")},
      payload: %{"channel" => %{"name" => channel.name}},
      occurred_at: DateTime.truncate(now, :second)
    }
  end
end
