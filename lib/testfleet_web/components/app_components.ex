defmodule TestFleetWeb.AppComponents do
  @moduledoc """
  Building blocks for TestFleet pages: page headers, stat tiles, panels, and empty states.
  """
  use Phoenix.Component
  use Gettext, backend: TestFleetWeb.Gettext

  import TestFleetWeb.CoreComponents, only: [icon: 1, input: 1]

  @doc """
  Renders a UTC timestamp in a time zone, e.g. "Sun 27 Sep 2026, 06:00 CEST".

  ## Examples

      <.local_time at={@schedule.next_run_at} timezone={@schedule.timezone} />
  """
  attr :at, DateTime, required: true
  attr :timezone, :string, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil

  def local_time(assigns) do
    assigns = assign(assigns, :local, DateTime.shift_zone!(assigns.at, assigns.timezone))

    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@at)}
      title={"#{Calendar.strftime(@at, "%Y-%m-%d %H:%M")} UTC · #{@timezone}"}
      class={["tabular-nums", @class]}
    >
      {Calendar.strftime(@local, "%a %-d %b %Y, %H:%M %Z")}
    </time>
    """
  end

  @doc """
  Renders the slug input of a form whose changeset generates an empty slug from
  another field (see `TestFleet.Slug`).

  The input shows only what the user typed; the generated slug is previewed as the
  placeholder. Showing the generated value in the input would send it back with the
  next keystroke, where it would count as typed by hand and stop following the name.

  ## Examples

      <.slug_input field={@form[:slug]} source={@form[:name]} label="Slug" />
  """
  attr :field, Phoenix.HTML.FormField, required: true

  attr :source, Phoenix.HTML.FormField,
    required: true,
    doc: "the field the slug is generated from"

  attr :label, :string, required: true
  attr :hint, :string, default: nil

  def slug_input(assigns) do
    %{form: form, field: field} = assigns.field
    key = Atom.to_string(field)

    typed =
      if Map.has_key?(form.params, key),
        do: form.params[key],
        else: Map.get(form.data, field)

    preview = TestFleet.Slug.slugify(assigns.source.value)

    assigns =
      assigns
      |> assign(:value, typed)
      |> assign(
        :placeholder,
        if(preview == "", do: gettext("generated from the name"), else: preview)
      )

    ~H"""
    <.input
      field={@field}
      value={@value}
      label={@label}
      placeholder={@placeholder}
      hint={@hint}
    />
    """
  end

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
  slot :actions

  def panel(assigns) do
    ~H"""
    <section id={@id} class={["rounded-xl border border-base-300 bg-base-100", @class]}>
      <div class="flex min-h-12 items-center justify-between gap-3 border-b border-base-300 px-5 py-2">
        <h2 class="text-sm font-semibold">{@title}</h2>
        <div :if={@actions != []} class="flex items-center gap-1">{render_slot(@actions)}</div>
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  @doc """
  Renders a small label, e.g. for a slug or a limit.
  """
  attr :tone, :atom, default: :neutral, values: [:neutral, :primary, :warning]
  attr :class, :any, default: nil
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def badge(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-md px-1.5 py-0.5 text-xs font-medium",
        @tone == :neutral && "bg-base-200 text-base-content/70",
        @tone == :primary && "bg-primary/10 text-primary",
        @tone == :warning && "bg-warning/15 text-warning",
        @class
      ]}
      title={@title}
    >
      {render_slot(@inner_block)}
    </span>
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

  attr :class, :any,
    default: "flex",
    doc: "display classes; use `hidden only:flex` as the placeholder of a stream"

  slot :inner_block, doc: "the explanation below the title"
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "flex-col items-center justify-center text-center",
        @class,
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
      <div :if={@actions != []} class="mt-5 flex gap-2">{render_slot(@actions)}</div>
    </div>
    """
  end

  @doc """
  Renders the path to the current page. The last crumb is the current page and
  has no link.

  ## Examples

      <.breadcrumbs>
        <:crumb navigate={~p"/projects"}>Projects</:crumb>
        <:crumb>{@project.name}</:crumb>
      </.breadcrumbs>
  """
  slot :crumb, required: true do
    attr :navigate, :string
  end

  def breadcrumbs(assigns) do
    ~H"""
    <nav aria-label="Breadcrumb" class="mb-3">
      <ol class="flex flex-wrap items-center gap-1.5 text-sm text-base-content/60">
        <li :for={{crumb, index} <- Enum.with_index(@crumb)} class="flex items-center gap-1.5">
          <.icon :if={index > 0} name="hero-chevron-right-mini" class="size-4 text-base-content/30" />
          <.link
            :if={crumb[:navigate]}
            navigate={crumb.navigate}
            class="transition-colors hover:text-base-content"
          >
            {render_slot(crumb)}
          </.link>
          <span :if={!crumb[:navigate]} aria-current="page" class="text-base-content/80">
            {render_slot(crumb)}
          </span>
        </li>
      </ol>
    </nav>
    """
  end

  @doc """
  Renders the card that holds a form, with the buttons in a footer.
  """
  slot :inner_block, required: true
  slot :footer, required: true

  def form_card(assigns) do
    ~H"""
    <div class="max-w-2xl overflow-hidden rounded-xl border border-base-300 bg-base-100">
      <div class="space-y-5 p-6">{render_slot(@inner_block)}</div>
      <div class="flex items-center justify-end gap-2 border-t border-base-300 bg-base-200/40 px-6 py-4">
        {render_slot(@footer)}
      </div>
    </div>
    """
  end
end
