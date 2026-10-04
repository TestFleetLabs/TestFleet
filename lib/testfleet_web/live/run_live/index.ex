defmodule TestFleetWeb.RunLive.Index do
  @moduledoc """
  The latest runs of all projects, newest first, updated live.
  """
  use TestFleetWeb, :live_view

  alias TestFleet.Runs
  alias TestFleetWeb.RunFeed

  @limit 50

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Runs.subscribe(socket.assigns.current_scope)

    {:ok,
     socket
     |> assign(:page_title, gettext("Runs"))
     |> RunFeed.init(:runs, Runs.list_runs(socket.assigns.current_scope, limit: @limit))}
  end

  @impl true
  def handle_info({event, _run} = message, socket)
      when event in [:run_created, :run_updated, :run_finished] do
    {:noreply, RunFeed.apply_event(socket, :runs, message, @limit)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active={:runs}>
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
