defmodule TestFleetWeb.RunLive.Index do
  use TestFleetWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, gettext("Runs"))}
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

        <.empty_state id="runs-empty" icon="hero-play-circle" title={gettext("No runs yet")}>
          {gettext(
            "Runs appear here when a test definition is started manually, by a schedule, or through the API."
          )}
        </.empty_state>
      </div>
    </Layouts.app>
    """
  end
end
