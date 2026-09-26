defmodule TestFleetWeb.AppComponents do
  @moduledoc """
  Building blocks for TestFleet pages: page headers, stat tiles, panels, and empty states.
  """
  use Phoenix.Component

  import TestFleetWeb.CoreComponents, only: [icon: 1]

  @doc """
  Renders the title row of a page.

  ## Examples

      <.page_header title="Runs" description="Every execution, newest first.">
        <:actions><.button>Run now</.button></:actions>
      </.page_header>
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  slot :actions

  def page_header(assigns) do
    ~H"""
    <div class="flex flex-wrap items-end justify-between gap-4 border-b border-base-300 pb-6">
      <div class="min-w-0">
        <h1 class="text-2xl font-semibold tracking-tight">{@title}</h1>
        <p :if={@description} class="mt-1 text-sm text-base-content/60">{@description}</p>
      </div>
      <div :if={@actions != []} class="flex shrink-0 items-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a single figure with a label, e.g. the number of running runs.
  """
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true
  attr :tone, :atom, default: :neutral, values: [:neutral, :info, :success, :error, :warning]

  def stat_tile(assigns) do
    ~H"""
    <div
      id={@id}
      class="rounded-xl border border-base-300 bg-base-100 p-5 transition-shadow duration-200 hover:shadow-md hover:shadow-base-300/40"
    >
      <div class="flex items-center justify-between gap-3">
        <p class="text-sm font-medium text-base-content/60">{@label}</p>
        <span class={["grid size-8 place-items-center rounded-lg", tone_classes(@tone)]}>
          <.icon name={@icon} class="size-4" />
        </span>
      </div>
      <p class="mt-3 text-3xl font-semibold tracking-tight tabular-nums">{@value}</p>
    </div>
    """
  end

  defp tone_classes(:neutral), do: "bg-base-200 text-base-content/60"
  defp tone_classes(:info), do: "bg-info/10 text-info"
  defp tone_classes(:success), do: "bg-success/10 text-success"
  defp tone_classes(:error), do: "bg-error/10 text-error"
  defp tone_classes(:warning), do: "bg-warning/10 text-warning"

  @doc """
  Renders a titled card section.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-base-300 bg-base-100", @class]}>
      <h2 class="border-b border-base-300 px-5 py-3.5 text-sm font-semibold">{@title}</h2>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders the placeholder for a list without entries.

  Use `compact` inside panels.
  """
  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :compact, :boolean, default: false
  slot :inner_block, doc: "the explanation below the title"

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex flex-col items-center justify-center text-center",
        if(@compact,
          do: "px-6 py-10",
          else: "rounded-2xl border border-dashed border-base-300 bg-base-100 px-6 py-16"
        )
      ]}
    >
      <span class={[
        "grid place-items-center rounded-full bg-base-200 text-base-content/50",
        if(@compact, do: "size-10", else: "size-12")
      ]}>
        <.icon name={@icon} class={if(@compact, do: "size-5", else: "size-6")} />
      </span>
      <h3 class="mt-4 text-sm font-semibold">{@title}</h3>
      <p :if={@inner_block != []} class="mt-1 max-w-md text-sm text-base-content/60">
        {render_slot(@inner_block)}
      </p>
    </div>
    """
  end
end
