defmodule TestFleetWeb.RateLimit do
  @moduledoc """
  Counts attempts per key in fixed windows, in memory (ETS): enough to slow down
  password guessing and to keep the login form from sending mail without limit.

  The counters are per node and lost on a restart, which is fine for that purpose.
  This process owns the table and removes expired windows once a minute.

      case RateLimit.hit({:login, email}, 10, :timer.minutes(15)) do
        :ok -> ...
        {:error, :rate_limited} -> ...
      end
  """
  use GenServer

  @table __MODULE__
  @prune_interval 60_000

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Counts one attempt for `key`. `{:error, :rate_limited}` once there were more than
  `limit` in the current window of `window_ms`.
  """
  @spec hit(term(), pos_integer(), pos_integer()) :: :ok | {:error, :rate_limited}
  def hit(key, limit, window_ms) do
    now = System.system_time(:millisecond)
    window = div(now, window_ms)
    expires_at = (window + 1) * window_ms

    count =
      :ets.update_counter(@table, {key, window}, {2, 1}, {{key, window}, 0, expires_at})

    if count > limit, do: {:error, :rate_limited}, else: :ok
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    schedule_prune()
    {:ok, nil}
  end

  @impl true
  def handle_info(:prune, state) do
    now = System.system_time(:millisecond)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_prune()
    {:noreply, state}
  end

  defp schedule_prune, do: Process.send_after(self(), :prune, @prune_interval)
end
