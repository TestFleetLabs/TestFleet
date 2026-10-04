defmodule TestFleetWeb.RegistryConnectionTest do
  # "Test connection" against the fixture registry through the real Docker Engine.
  # Needs: docker compose --profile registry up -d.
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.RegistriesFixtures

  alias TestFleet.Registries

  setup :register_and_log_in_admin

  @moduletag :docker

  @registry %{host: "localhost:5055", username: "fixture", password: "fixture-password"}

  test "the context logs in with good credentials and reports bad ones" do
    assert :ok = Registries.test_connection(%TestFleet.Registries.Registry{}, @registry)

    assert {:error, message} =
             Registries.test_connection(%TestFleet.Registries.Registry{}, %{
               @registry
               | password: "wrong"
             })

    assert message =~ "401"
  end

  test "a new registry can be tested before it is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/#{org()}/registries/new")

    view
    |> form("#registry-form", registry: Map.put(@registry, :name, "Fixtures"))
    |> render_change()

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-ok")
  end

  test "an existing registry is tested with its stored password", %{conn: conn} do
    registry = registry_fixture(Map.put(@registry, :name, "Fixtures"))
    {:ok, view, _html} = live(conn, ~p"/#{org()}/registries/#{registry.id}/edit")

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-ok")
  end

  test "wrong credentials show Docker's message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/#{org()}/registries/new")

    view
    |> form("#registry-form",
      registry: %{@registry | password: "wrong"} |> Map.put(:name, "Fixtures")
    )
    |> render_change()

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-error", "401")
  end
end
