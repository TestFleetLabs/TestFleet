defmodule TestFleetWeb.NavigationTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  setup :register_and_log_in_admin

  defp pages do
    [
      {~p"/#{org()}", "#dashboard", "#nav-dashboard"},
      {~p"/#{org()}/projects", "#projects", "#nav-projects"},
      {~p"/#{org()}/runs", "#runs", "#nav-runs"},
      {~p"/#{org()}/registries", "#registries", "#nav-registries"}
    ]
  end

  test "every page renders inside the layout and highlights only its own entry", %{conn: conn} do
    for {path, page, nav_entry} <- pages() do
      {:ok, view, _html} = live(conn, path)

      assert has_element?(view, page), "#{path} renders #{page}"
      assert has_element?(view, "#sidebar")
      assert has_element?(view, "#{nav_entry}[aria-current=page]")
      refute has_element?(view, "#nav a[aria-current=page]:not(#{nav_entry})")
    end
  end

  test "the sidebar navigates between pages", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/#{org()}")

    {:ok, view, _html} =
      view |> element("#nav-runs") |> render_click() |> follow_redirect(conn, ~p"/#{org()}/runs")

    assert has_element?(view, "#runs")

    {:ok, view, _html} =
      view
      |> element("#nav-registries")
      |> render_click()
      |> follow_redirect(conn, ~p"/#{org()}/registries")

    assert has_element?(view, "#registries")
  end

  test "the mobile navigation has the same entries", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/#{org()}/projects")

    assert has_element?(view, "#mobile-nav-toggle[aria-controls=mobile-menu]")

    for key <- ~w(dashboard projects runs registries) do
      assert has_element?(view, "#mobile-nav-#{key}")
    end

    assert has_element?(view, "#mobile-nav-projects[aria-current=page]")
  end

  test "pages set their title", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/#{org()}/runs")
    assert page_title(view) == "Runs · TestFleet"
  end
end
