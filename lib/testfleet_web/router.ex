defmodule TestFleetWeb.Router do
  use TestFleetWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TestFleetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TestFleetWeb do
    pipe_through :browser

    # Authentication (OIDC) will add an on_mount hook and current_scope here.
    live_session :default do
      live "/", DashboardLive, :index
      live "/projects", ProjectLive.Index, :index
      live "/projects/new", ProjectLive.Form, :new
      live "/projects/:slug", ProjectLive.Show, :show
      live "/projects/:slug/edit", ProjectLive.Form, :edit
      live "/projects/:slug/test-definitions/new", TestDefinitionLive.Form, :new
      live "/projects/:slug/test-definitions/:id", TestDefinitionLive.Show, :show
      live "/projects/:slug/test-definitions/:id/edit", TestDefinitionLive.Form, :edit
      live "/projects/:slug/schedules/new", ScheduleLive.Form, :new
      live "/projects/:slug/schedules/:id/edit", ScheduleLive.Form, :edit
      live "/projects/:slug/environments/new", EnvironmentLive.Form, :new
      live "/projects/:slug/environments/:env", EnvironmentLive.Show, :show
      live "/projects/:slug/environments/:env/edit", EnvironmentLive.Form, :edit
      live "/runs", RunLive.Index, :index
      live "/runs/:id", RunLive.Show, :show
      live "/registries", RegistryLive.Index, :index
      live "/registries/new", RegistryLive.Form, :new
      live "/registries/:id/edit", RegistryLive.Form, :edit
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", TestFleetWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:testfleet, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TestFleetWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
