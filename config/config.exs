# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :testfleet, :scopes,
  user: [
    default: true,
    module: TestFleet.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: TestFleet.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :testfleet,
  # Without this, Phoenix generators derive "Testfleet" from the app name
  namespace: TestFleet,
  ecto_repos: [TestFleet.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :testfleet, TestFleetWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TestFleetWeb.ErrorHTML, json: TestFleetWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TestFleet.PubSub,
  live_view: [signing_salt: "Uc+rJzLb"]

# Background jobs (main spec section 28). Oban creates runs and does fire-and-forget
# work; it never starts or owns a running container.
config :testfleet, Oban,
  engine: Oban.Engines.Basic,
  repo: TestFleet.Repo,
  queues: [default: 10, schedules: 1, notifications: 5, cleanup: 1],
  # One static entry drives all user-defined schedules (Milestone 5, section 4).
  cron: [
    crontab: [
      {"* * * * *", TestFleet.Schedules.TickWorker},
      {"0 * * * *", TestFleet.Artifacts.CleanupWorker}
    ]
  ],
  pruner: [max_age: 7 * 24 * 60 * 60],
  # Rescues TestFleet's own jobs; runs are recovered by the reconciler, never by Oban.
  lifeline: [rescue_after: :timer.minutes(30)]

# Password (and magic-link) login; AUTH_PASSWORD_LOGIN=false makes TestFleet "SSO
# button only" (Milestone 10, section 4)
config :testfleet, TestFleet.Accounts, password_login: true

# Time zones for schedules (IANA database, bundled with the tz package)
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Preselected in new schedules
config :testfleet, :default_timezone, "Europe/Vienna"

# Admission control (main spec section 34). The global limit can be set at runtime
# with MAX_CONCURRENT_RUNS; each environment has its own limit on top.
config :testfleet, TestFleet.Execution.Dispatcher,
  max_concurrent_runs: 10,
  poll_interval: 5_000

# Stored log size per run; later output is only streamed live. RUN_LOG_LIMIT_MB at runtime.
config :testfleet, TestFleet.Runs, max_log_bytes: 50 * 1024 * 1024

# Artifacts per run: <root>/<run_id>/ (ARTIFACTS_DIR, and ARTIFACT_LIMIT_MB at runtime)
config :testfleet, TestFleet.Artifacts,
  root: "tmp/artifacts",
  max_bytes: 500 * 1024 * 1024

# Image pulls have their own timeout, separate from the run's (Milestone 7 section 6;
# PULL_TIMEOUT_SECONDS at runtime). Digests no run used for image_retention_days are
# removed (section 8; IMAGE_RETENTION_DAYS).
config :testfleet, TestFleet.Execution,
  pull_timeout: :timer.minutes(10),
  image_retention_days: 7

# Notifications (Milestone 8). Email needs a mailer: the local one in dev, SMTP in
# production (SMTP_HOST and friends in config/runtime.exs).
config :testfleet, TestFleet.Notifications,
  email_enabled: true,
  email_from: "testfleet@localhost",
  # Extra Req options for Slack, Teams, and webhooks; tests stub them here.
  req_options: []

# TestFleet's own problems: Docker unreachable for 5 minutes, schedules more than 10
# minutes overdue (Milestone 8, section 7). HEARTBEAT_URL pings an external dead
# man's switch after each schedule tick.
config :testfleet, TestFleet.Notifications.Watchdog,
  interval: :timer.minutes(1),
  docker_alert_after: :timer.minutes(5),
  schedule_alert_after: :timer.minutes(10)

config :testfleet, TestFleet.Notifications.Heartbeat, url: nil, req_options: []

# Retention (Milestone 6 section 8; ARTIFACT_RETENTION_DAYS and LOG_RETENTION_DAYS)
config :testfleet, TestFleet.Retention,
  artifacts_days: 30,
  logs_days: 90

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :testfleet, TestFleet.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  testfleet: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  testfleet: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
