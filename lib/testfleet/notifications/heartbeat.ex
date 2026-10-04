defmodule TestFleet.Notifications.Heartbeat do
  @moduledoc """
  Pings an external dead man's switch, such as Healthchecks.io, after each
  completed schedule tick. The external system alerts when
  the pings stop: the one failure TestFleet cannot report itself is being down.

      config :testfleet, TestFleet.Notifications.Heartbeat,
        url: "https://hc-ping.com/…"   # HEARTBEAT_URL

  A ping is one `GET`, with a 10-second timeout and no retries: the next tick pings
  again. A failure is logged once per streak of failures, never with the URL, which
  often carries a token.
  """

  require Logger

  @failing_key {__MODULE__, :failing}
  @timeout 10_000

  @doc "Pings, if a URL is configured. Returns `:ok`, `:disabled`, or `{:error, reason}`."
  def ping do
    case config(:url) do
      url when url in [nil, ""] -> :disabled
      url -> url |> request() |> record()
    end
  end

  defp request(url) do
    options =
      Keyword.merge(
        [
          method: :get,
          url: url,
          retry: false,
          redirect: false,
          receive_timeout: @timeout,
          connect_options: [timeout: @timeout]
        ],
        config(:req_options) || []
      )

    case Req.request(options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      {:ok, %Req.Response{status: status}} -> {:error, "HTTP #{status}"}
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  # Logged on the change, not on every tick.
  defp record(:ok) do
    if :persistent_term.get(@failing_key, false) do
      :persistent_term.erase(@failing_key)
      Logger.info("heartbeat ping succeeds again")
    end

    :ok
  end

  defp record({:error, reason} = error) do
    unless :persistent_term.get(@failing_key, false) do
      :persistent_term.put(@failing_key, true)
      Logger.warning("heartbeat ping failed: #{reason}")
    end

    error
  end

  defp config(key), do: Application.get_env(:testfleet, __MODULE__, [])[key]
end
