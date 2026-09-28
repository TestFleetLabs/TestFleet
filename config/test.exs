import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :testfleet, TestFleet.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5433,
  database: "testfleet_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :testfleet, TestFleetWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "3bbDwi4jKLfuFf+ifl3SBAIaS0+9icYgzRN2jx2Yxmr/spIoM5HZsD1flPUBmuKY",
  server: false

# Encryption at rest; test only
config :testfleet, TestFleet.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1",
       key: Base.decode64!("UqH+t8NVuYJGt8eBiagih8Ti/tPEwkIKMhp+JFtUMWE="),
       iv_length: 12}
  ]

# Tests start the dispatcher themselves (start_supervised!), usually with a fake engine.
# Startup recovery talks to Docker, so only the Docker tests turn it on.
config :testfleet, TestFleet.Execution.Dispatcher, start: false, recover: false

# Kept apart from the dev artifacts
config :testfleet, TestFleet.Artifacts, root: "tmp/test_artifacts"

# Jobs are inserted but not executed; tests run them explicitly with Oban.Testing
config :testfleet, Oban, testing: :manual

# In test we don't send emails
config :testfleet, TestFleet.Mailer, adapter: Swoosh.Adapters.Test

# Slack, Teams, and webhook requests go to Req.Test stubs
config :testfleet, TestFleet.Notifications,
  req_options: [plug: {Req.Test, TestFleet.Notifications}]

# Tests start the watchdog themselves, with a fake clock and Docker status.
config :testfleet, TestFleet.Notifications.Watchdog, enabled: false

config :testfleet, TestFleet.Notifications.Heartbeat,
  req_options: [plug: {Req.Test, TestFleet.Notifications.Heartbeat}]

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
