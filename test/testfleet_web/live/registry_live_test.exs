defmodule TestFleetWeb.RegistryLiveTest do
  use TestFleetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import TestFleet.RegistriesFixtures

  alias TestFleet.Registries

  describe "index" do
    test "lists registries with their host and username", %{conn: conn} do
      registry = registry_fixture(name: "Company GitLab", host: "registry.company.com")
      {:ok, view, _html} = live(conn, ~p"/registries")

      assert has_element?(view, "#registries-#{registry.id}", "Company GitLab")
      assert has_element?(view, "#registries-#{registry.id}", "registry.company.com")

      assert has_element?(
               view,
               "#edit-registry-#{registry.id}[href='/registries/#{registry.id}/edit']"
             )

      refute has_element?(view, "#registries-empty")
    end

    test "deletes a registry", %{conn: conn} do
      registry = registry_fixture()
      {:ok, view, _html} = live(conn, ~p"/registries")

      view |> element("#delete-registry-#{registry.id}") |> render_click()

      refute has_element?(view, "#registries-#{registry.id}")
      assert has_element?(view, "#registries-empty")
      assert Registries.list_registries() == []
    end
  end

  describe "form" do
    test "creates a registry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/registries/new")

      {:ok, index, _html} =
        view
        |> form("#registry-form",
          registry: %{
            name: "Company GitLab",
            host: "Registry.Company.com",
            username: "deploy",
            password: "s3cret-token"
          }
        )
        |> render_submit()
        |> follow_redirect(conn, ~p"/registries")

      assert [registry] = Registries.list_registries()
      assert {registry.host, registry.password} == {"registry.company.com", "s3cret-token"}
      assert has_element?(index, "#registries-#{registry.id}")
    end

    test "shows validation errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/registries/new")

      view
      |> form("#registry-form", registry: %{name: "X", host: "https://x.com", username: ""})
      |> render_submit()

      assert has_element?(view, "#registry-form #registry_host.border-error")
      assert has_element?(view, "#registry-form #registry_password.border-error")
      assert Registries.list_registries() == []
    end

    test "editing with an empty password keeps it", %{conn: conn} do
      registry = registry_fixture(password: "s3cret-token")
      {:ok, view, _html} = live(conn, ~p"/registries/#{registry.id}/edit")

      view
      |> form("#registry-form", registry: %{name: "Renamed", password: ""})
      |> render_submit()

      assert %{name: "Renamed", password: "s3cret-token"} = Registries.get_registry!(registry.id)
    end

    # Security: these checks are about what reaches the browser, so they look at the HTML.
    test "the stored password never reaches the browser", %{conn: conn} do
      registry = registry_fixture(password: "s3cret-token")

      {:ok, _view, html} = live(conn, ~p"/registries")
      refute html =~ "s3cret-token"

      {:ok, view, html} = live(conn, ~p"/registries/#{registry.id}/edit")
      refute html =~ "s3cret-token"
      assert has_element?(view, "#registry-form #registry_password[type=password]")

      # A failed save must not echo the stored password either.
      view
      |> form("#registry-form", registry: %{host: "https://bad", password: ""})
      |> render_submit()

      refute render(view) =~ "s3cret-token"
    end

    test "test connection asks for complete credentials first", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/registries/new")

      view |> form("#registry-form", registry: %{host: "registry.company.com"}) |> render_change()
      view |> element("#test-connection") |> render_click()

      render_async(view)

      assert has_element?(
               view,
               "#connection-error",
               "Enter the host, username, and password first."
             )
    end

    test "changing a field clears the previous test result", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/registries/new")

      view |> element("#test-connection") |> render_click()
      render_async(view)
      assert has_element?(view, "#connection-error")

      view |> form("#registry-form", registry: %{name: "Company GitLab"}) |> render_change()
      refute has_element?(view, "#connection-result")
    end
  end
end
