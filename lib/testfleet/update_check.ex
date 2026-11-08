defmodule TestFleet.UpdateCheck do
  @moduledoc """
  Tells admins when a newer TestFleet release is out. A GenServer that asks
  GitHub for the latest release (`GET /repos/<repo>/releases/latest`, which skips
  drafts and prereleases) at start and once per `:interval` (default 12 h), and
  keeps a newer one in `:persistent_term`, where the layout reads it on every
  render without a call.

  It only reads: TestFleet never downloads or installs anything, and the request
  carries nothing but the installed version in the `User-Agent`. A failed check
  keeps what the last one found and is logged once per streak of failures.

  Options (default from `config :testfleet, #{inspect(__MODULE__)}`): `:enabled`
  (`UPDATE_CHECK=false`; `false` makes `start_link/1` return `:ignore`), `:repo`,
  `:interval` (milliseconds), `:req_options`, and for tests `:name` and
  `:current_version`. In `:multi` mode (the hosted edition) it never starts: the
  operator upgrades, not the organizations' admins.
  """
  use GenServer

  require Logger

  alias TestFleet.Organizations

  @defaults [
    enabled: true,
    repo: "testfleetlabs/testfleet",
    interval: :timer.hours(12),
    req_options: []
  ]

  @key {__MODULE__, :available}
  @timeout 10_000

  @doc """
  The newer release, `%{version: "0.5.0", url: "https://github.com/…"}`, or nil
  when there is none or no check found one.
  """
  def available, do: :persistent_term.get(@key, nil)

  @doc "The installed version."
  def current_version, do: to_string(Application.spec(:testfleet, :vsn))

  def start_link(opts \\ []) do
    config =
      @defaults
      |> Keyword.merge(Application.get_env(:testfleet, __MODULE__, []))
      |> Keyword.merge(opts)

    if config[:enabled] and not Organizations.multi?(),
      do: GenServer.start_link(__MODULE__, config, name: Keyword.get(config, :name, __MODULE__)),
      else: :ignore
  end

  @doc "Checks now and waits for it. Returns what `available/0` returns afterwards."
  def check(server \\ __MODULE__), do: GenServer.call(server, :check, @timeout * 2)

  @impl true
  def init(config) do
    state =
      config
      |> Map.new()
      |> Map.put_new_lazy(:current_version, &current_version/0)
      |> Map.put(:failing, false)

    # Not in init: GitHub must not hold up the start.
    send(self(), :check)
    {:ok, state}
  end

  @impl true
  def handle_call(:check, _from, state) do
    state = run_check(state)
    {:reply, available(), state}
  end

  @impl true
  def handle_info(:check, state) do
    state = run_check(state)
    Process.send_after(self(), :check, state.interval)
    {:noreply, state}
  end

  defp run_check(state) do
    case fetch_latest(state) do
      {:ok, release} ->
        if state.failing, do: Logger.info("update check succeeds again")
        store(newer(release, state.current_version))
        %{state | failing: false}

      {:error, reason} ->
        unless state.failing,
          do: Logger.warning("update check failed: #{reason} (UPDATE_CHECK=false turns it off)")

        %{state | failing: true}
    end
  end

  defp fetch_latest(state) do
    options =
      Keyword.merge(
        [
          method: :get,
          url: "https://api.github.com/repos/#{state.repo}/releases/latest",
          headers: [
            accept: "application/vnd.github+json",
            user_agent: "TestFleet/#{state.current_version}"
          ],
          retry: false,
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout]
        ],
        state.req_options
      )

    case Req.request(options) do
      {:ok, %Req.Response{status: 200, body: %{"tag_name" => tag, "html_url" => url}}}
      when is_binary(tag) and is_binary(url) ->
        {:ok, %{tag: tag, url: url}}

      # No release published yet
      {:ok, %Req.Response{status: 404}} ->
        {:ok, nil}

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  # Tags are "v" + the version in mix.exs (section 43).
  defp newer(nil, _current), do: nil

  defp newer(%{tag: tag, url: url}, current) do
    with {:ok, latest} <- Version.parse(String.trim_leading(tag, "v")),
         {:ok, current} <- Version.parse(current),
         :gt <- Version.compare(latest, current) do
      %{version: to_string(latest), url: url}
    else
      _ -> nil
    end
  end

  # Written only on a change: a :persistent_term update scans every process.
  defp store(value) do
    if available() != value do
      if value,
        do: :persistent_term.put(@key, value),
        else: :persistent_term.erase(@key)
    end
  end
end
