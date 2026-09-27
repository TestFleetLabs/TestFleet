defmodule TestFleetWeb.RunFeed do
  @moduledoc """
  A LiveView stream of the newest runs, kept current from the `runs` topic.

      socket = RunFeed.init(socket, :runs, Runs.list_runs(limit: 20))

      def handle_info({event, %Run{}} = message, socket)
          when event in [:run_created, :run_updated, :run_finished] do
        {:noreply, RunFeed.apply_event(socket, :runs, message, 20)}
      end

  New runs go on top, and the list keeps at most `limit` entries. Updates only touch
  runs that are shown: a stream insert of any other run would append it at the
  bottom. The ids shown are kept per stream in the `:run_feed_ids` assign.

  Filtering (a project, a test definition) is the caller's job: pass only the
  messages whose run belongs in the list.
  """
  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [stream: 3, stream_insert: 3, stream_insert: 4]

  def init(socket, name, runs) do
    ids = Map.get(socket.assigns, :run_feed_ids, %{})

    socket
    |> assign(:run_feed_ids, Map.put(ids, name, Enum.map(runs, & &1.id)))
    |> stream(name, runs)
  end

  def apply_event(socket, name, {:run_created, run}, limit) do
    socket
    |> update(
      :run_feed_ids,
      &Map.update!(&1, name, fn ids -> Enum.take([run.id | ids], limit) end)
    )
    |> stream_insert(name, run, at: 0, limit: limit)
  end

  def apply_event(socket, name, {_event, run}, _limit) do
    if run.id in socket.assigns.run_feed_ids[name],
      do: stream_insert(socket, name, run),
      else: socket
  end
end
