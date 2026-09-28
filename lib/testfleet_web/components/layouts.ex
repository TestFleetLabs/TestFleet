defmodule TestFleetWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TestFleetWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the app layout: a sidebar on large screens, a top bar with a
  slide-down menu on small ones.

  ## Examples

      <Layouts.app flash={@flash} active={:runs}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://phoenix.hexdocs.pm/scopes.html)"

  attr :active, :atom,
    default: nil,
    values: [nil, :dashboard, :projects, :runs, :registries, :notifications],
    doc: "the navigation entry to highlight"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen bg-base-200/50">
      <aside
        id="sidebar"
        class="fixed inset-y-0 left-0 z-30 hidden w-64 flex-col border-r border-base-300 bg-base-100 lg:flex"
      >
        <.brand class="h-16 px-5" />
        <.main_nav id="nav" active={@active} class="flex-1 px-3 py-4" />
        <div class="flex items-center justify-between border-t border-base-300 px-5 py-4">
          <span class="text-xs text-base-content/50 tabular-nums">
            v{Application.spec(:testfleet, :vsn)}
          </span>
          <.theme_toggle />
        </div>
      </aside>

      <header class="sticky top-0 z-30 border-b border-base-300 bg-base-100/90 backdrop-blur lg:hidden">
        <div class="flex h-14 items-center justify-between px-4">
          <.brand />
          <button
            id="mobile-nav-toggle"
            type="button"
            aria-label={gettext("Toggle navigation")}
            aria-controls="mobile-menu"
            aria-expanded="false"
            class="grid size-9 cursor-pointer place-items-center rounded-lg text-base-content/70 transition-colors hover:bg-base-200 hover:text-base-content"
            phx-click={toggle_mobile_nav()}
          >
            <.icon name="hero-bars-3" class="size-5" />
          </button>
        </div>
        <div id="mobile-menu" class="hidden border-t border-base-300">
          <.main_nav id="mobile-nav" active={@active} class="px-3 py-3" />
          <div class="flex justify-end px-4 pb-3">
            <.theme_toggle />
          </div>
        </div>
      </header>

      <main class="lg:pl-64">
        <div class="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-10 lg:py-10">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  defp toggle_mobile_nav do
    JS.toggle(
      to: "#mobile-menu",
      in:
        {"transition ease-out duration-150", "opacity-0 -translate-y-1",
         "opacity-100 translate-y-0"},
      out:
        {"transition ease-in duration-100", "opacity-100 translate-y-0",
         "opacity-0 -translate-y-1"}
    )
    |> JS.toggle_attribute({"aria-expanded", "true", "false"}, to: "#mobile-nav-toggle")
  end

  attr :class, :any, default: nil

  defp brand(assigns) do
    ~H"""
    <.link navigate={~p"/"} class={["group flex items-center gap-2.5", @class]}>
      <span class="grid size-8 place-items-center rounded-lg bg-primary text-primary-content shadow-sm transition-transform duration-200 group-hover:-rotate-6">
        <.icon name="hero-rocket-launch" class="size-5" />
      </span>
      <span class="text-base font-semibold tracking-tight">TestFleet</span>
    </.link>
    """
  end

  attr :id, :string, required: true, doc: "prefix for the ids of the entries"
  attr :active, :atom, default: nil
  attr :class, :any, default: nil

  defp main_nav(assigns) do
    assigns = assign(assigns, :items, nav_items())

    ~H"""
    <nav id={@id} aria-label={gettext("Main")} class={@class}>
      <ul class="space-y-1">
        <li :for={{key, label, icon, path} <- @items}>
          <.link
            navigate={path}
            id={"#{@id}-#{key}"}
            aria-current={if(key == @active, do: "page")}
            class={[
              "group flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors duration-150",
              if(key == @active,
                do: "bg-primary/10 text-primary",
                else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <.icon
              name={icon}
              class={[
                "size-5 transition-colors duration-150",
                if(key == @active,
                  do: "text-primary",
                  else: "text-base-content/40 group-hover:text-base-content/70"
                )
              ]}
            />
            {label}
          </.link>
        </li>
      </ul>
    </nav>
    """
  end

  defp nav_items do
    [
      {:dashboard, gettext("Dashboard"), "hero-squares-2x2", ~p"/"},
      {:projects, gettext("Projects"), "hero-folder", ~p"/projects"},
      {:runs, gettext("Runs"), "hero-play-circle", ~p"/runs"},
      {:registries, gettext("Registries"), "hero-server-stack", ~p"/registries"},
      {:notifications, gettext("Notifications"), "hero-bell", ~p"/notifications"}
    ]
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
