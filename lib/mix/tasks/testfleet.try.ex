defmodule Mix.Tasks.Testfleet.Try do
  @shortdoc "Runs one container through the execution engine and prints its events"

  @moduledoc """
  Runs one container against the real Docker Engine and prints events as they arrive.
  For looking at behaviour by hand; the `:docker` integration tests are the proof.

      mix testfleet.try --image testfleet/fixture-suite:dev --env FIXTURE_MODE=chatty --timeout 60

  Options:

    * `--image` - image reference (required)
    * `--env KEY=VALUE` - environment variable, repeatable
    * `--timeout` - timeout in seconds (default 300)
    * `--pull` - `auto`, `always`, `if_missing` or `never` (default `if_missing`)
    * `--artifacts` - directory to copy artifacts into
    * `--username`, `--password` - registry credentials

  Everything after `--` is the command, e.g. `-- sh -c "echo hi"`.
  """

  use Mix.Task

  alias TestFleet.Execution
  alias TestFleet.Execution.Request

  @switches [
    image: :string,
    env: :keep,
    timeout: :integer,
    pull: :string,
    artifacts: :string,
    username: :string,
    password: :string
  ]

  @pull_policies %{
    "auto" => :auto,
    "always" => :always,
    "if_missing" => :if_missing,
    "never" => :never
  }

  @impl true
  def run(args) do
    {args, command} = split_command(args)
    {opts, _rest} = OptionParser.parse!(args, strict: @switches)
    image = opts[:image] || Mix.raise("--image is required")

    Mix.Task.run("app.start")

    request =
      Request.new(%{
        run_id: System.os_time(:millisecond),
        image: image,
        command: command,
        environment: opts |> Keyword.get_values(:env) |> Map.new(&parse_env/1),
        timeout_seconds: opts[:timeout] || 300,
        pull_policy: pull_policy(opts[:pull] || "if_missing"),
        artifact_path: opts[:artifacts],
        registry_auth: opts[:username] && %{username: opts[:username], password: opts[:password]}
      })

    {:ok, _pid} = Execution.start(request)
    Mix.shell().info("run #{request.run_id}: started, Ctrl+C twice to abort")
    print_events(request.run_id)
  end

  defp print_events(run_id) do
    receive do
      {:run_event, ^run_id, {:output, lines}} ->
        for line <- lines do
          prefix = if line.stream == :stderr, do: "err", else: "out"

          Mix.shell().info(
            "#{String.pad_leading(to_string(line.sequence), 6)} #{prefix} | #{line.content}"
          )
        end

        print_events(run_id)

      {:run_event, ^run_id, {:finished, result}} ->
        Mix.shell().info("run #{run_id}: #{inspect(%{result | logs: []}, pretty: true)}")

      {:run_event, ^run_id, event} ->
        Mix.shell().info("run #{run_id}: #{inspect(event)}")
        print_events(run_id)
    end
  end

  defp split_command(args) do
    case Enum.split_while(args, &(&1 != "--")) do
      {args, ["--" | command]} -> {args, command}
      {args, []} -> {args, []}
    end
  end

  defp parse_env(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, value] -> {key, value}
      _ -> Mix.raise("--env expects KEY=VALUE, got #{inspect(pair)}")
    end
  end

  defp pull_policy(name) do
    Map.get(@pull_policies, name) ||
      Mix.raise("--pull must be one of #{Enum.join(Map.keys(@pull_policies), ", ")}")
  end
end
