defmodule TestFleetWeb.RegistryConnectionTest do
  # "Test connection" against the spike registry through the real Docker Engine.
  # Needs: docker compose --profile spike up -d (see .specs/execution-spike-spec.md).
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.RegistriesFixtures

  alias TestFleet.Registries

  @moduletag :docker

  @spike %{host: "localhost:5055", username: "spike", password: "spike-password"}

  test "the context logs in with good credentials and reports bad ones" do
    assert :ok = Registries.test_connection(%TestFleet.Registries.Registry{}, @spike)

    assert {:error, message} =
             Registries.test_connection(%TestFleet.Registries.Registry{}, %{
               @spike
               | password: "wrong"
             })

    assert message =~ "401"
  end

  test "a new registry can be tested before it is saved", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/registries/new")

    view
    |> form("#registry-form", registry: Map.put(@spike, :name, "Spike"))
    |> render_change()

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-ok")
  end

  test "an existing registry is tested with its stored password", %{conn: conn} do
    registry = registry_fixture(Map.put(@spike, :name, "Spike"))
    {:ok, view, _html} = live(conn, ~p"/registries/#{registry.id}/edit")

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-ok")
  end

  test "wrong credentials show Docker's message", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/registries/new")

    view
    |> form("#registry-form", registry: %{@spike | password: "wrong"} |> Map.put(:name, "Spike"))
    |> render_change()

    view |> element("#test-connection") |> render_click()
    render_async(view, 10_000)

    assert has_element?(view, "#connection-error", "401")
  end
end
