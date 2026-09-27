defmodule TestFleetWeb.RunLive.Index do
  @moduledoc """
  The latest runs of all projects, newest first, updated live.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Runs

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe()

    runs = Runs.list_runs(limit: @limit)

    {:ok,
     socket
     |> assign(:page_title, gettext("Runs"))
     |> assign(:oldest_id, runs |> List.last() |> then(&(&1 && &1.id)))
     |> stream(:runs, runs)}
  end

  @impl true
  def handle_info({:run_created, run}, socket) do
    {:noreply,
     socket
     |> update(:oldest_id, &(&1 || run.id))
     |> stream_insert(:runs, run, at: 0, limit: @limit)}
  end

  # Updates of runs older than the list would otherwise be appended to it.
  def handle_info({event, run}, socket) when event in [:run_updated, :run_finished] do
    oldest_id = socket.assigns.oldest_id

    if oldest_id && run.id >= oldest_id,
      do: {:noreply, stream_insert(socket, :runs, run)},
      else: {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:runs}>
      <div id="runs" class="space-y-8">
        <.page_header
          title={gettext("Runs")}
          description={gettext("Every execution of a test suite, newest first.")}
        />

        <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100">
          <ul id="run-list" phx-update="stream" class="divide-y divide-base-300">
            <li id="runs-empty" class="hidden only:block">
              <.empty_state
                id="runs-empty-state"
                icon="hero-play-circle"
                title={gettext("No runs yet")}
                compact
              >
                {gettext(
                  "Runs appear here when a test definition is started manually, by a schedule, or through the API."
                )}
              </.empty_state>
            </li>
            <.run_row :for={{id, run} <- @streams.runs} id={id} run={run} />
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
