defmodule TestFleetWeb.Router do
  use TestFleetWeb, :router

  import TestFleetWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TestFleetWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  # Artifacts are requested by <img>, <video>, and new tabs, which do not all accept
  # HTML. They need a session like every page (Milestone 10, section 6).
  pipeline :artifacts do
    plug :fetch_session
    plug :fetch_flash
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :require_authenticated_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Everything behind a login (Milestone 10, section 6). /health is answered in the
  # endpoint, before the router.
  scope "/", TestFleetWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{TestFleetWeb.UserAuth, :require_authenticated}] do
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
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    # Registries and notification channels hold credentials and send requests to
    # arbitrary URLs; users manage access (Milestone 10, section 5).
    live_session :require_admin,
      on_mount: [
        {TestFleetWeb.UserAuth, :require_authenticated},
        {TestFleetWeb.UserAuth, :require_admin}
      ] do
      live "/registries", RegistryLive.Index, :index
      live "/registries/new", RegistryLive.Form, :new
      live "/registries/:id/edit", RegistryLive.Form, :edit
      live "/notifications", NotificationLive.Index, :index
      live "/notifications/channels/new", NotificationLive.ChannelForm, :new
      live "/notifications/channels/:id/edit", NotificationLive.ChannelForm, :edit
      live "/users", UserLive.Index, :index
    end

    get "/runs/:id/log", RunLogController, :show
    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/", TestFleetWeb do
    pipe_through :artifacts

    get "/runs/:id/artifacts/*name", ArtifactController, :show
  end

  # Open: logging in, the first-run setup (with its token), and invitation links
  # (Milestone 10, section 4).
  scope "/", TestFleetWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TestFleetWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
      live "/users/invitations/:token", UserLive.Invitation, :new
      live "/setup", UserLive.Setup, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

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
