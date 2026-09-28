import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/testfleet start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :testfleet, TestFleetWeb.Endpoint, server: true
end

config :testfleet, TestFleetWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Docker Engine API endpoint: the socket proxy from compose.yaml, or unix:///var/run/docker.sock
config :testfleet, TestFleet.Execution.Docker,
  host: System.get_env("DOCKER_HOST", "tcp://localhost:2375")

# The global limit of concurrently executing runs (main spec section 34)
if max_concurrent_runs = System.get_env("MAX_CONCURRENT_RUNS") do
  config :testfleet, TestFleet.Execution.Dispatcher,
    max_concurrent_runs: String.to_integer(max_concurrent_runs)
end

if run_log_limit_mb = System.get_env("RUN_LOG_LIMIT_MB") do
  config :testfleet, TestFleet.Runs,
    max_log_bytes: String.to_integer(run_log_limit_mb) * 1024 * 1024
end

# Where artifacts are stored, and how much one run may keep (Milestone 6, section 4)
if artifacts_dir = System.get_env("ARTIFACTS_DIR") do
  config :testfleet, TestFleet.Artifacts, root: artifacts_dir
end

if artifact_limit_mb = System.get_env("ARTIFACT_LIMIT_MB") do
  config :testfleet, TestFleet.Artifacts,
    max_bytes: String.to_integer(artifact_limit_mb) * 1024 * 1024
end

if seconds = System.get_env("PULL_TIMEOUT_SECONDS") do
  config :testfleet, TestFleet.Execution, pull_timeout: String.to_integer(seconds) * 1000
end

if days = System.get_env("IMAGE_RETENTION_DAYS") do
  config :testfleet, TestFleet.Execution, image_retention_days: String.to_integer(days)
end

if days = System.get_env("ARTIFACT_RETENTION_DAYS") do
  config :testfleet, TestFleet.Retention, artifacts_days: String.to_integer(days)
end

if days = System.get_env("LOG_RETENTION_DAYS") do
  config :testfleet, TestFleet.Retention, logs_days: String.to_integer(days)
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :testfleet, TestFleetWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Gettext translations
        ~r"priv/gettext/.*\.po$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/testfleet_web/router\.ex$"E,
        ~r"lib/testfleet_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The mounted volume of the containerized deployment (main spec, amendment)
  config :testfleet, TestFleet.Artifacts,
    root: System.get_env("ARTIFACTS_DIR", "/var/lib/TestFleet/artifacts")

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :testfleet, TestFleet.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Encrypts environment variable values and registry passwords at rest.
  # Losing this key makes them unreadable. Generate one with:
  # mix run -e "32 |> :crypto.strong_rand_bytes() |> Base.encode64() |> IO.puts()"
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing (base64, 32 bytes).
      """

  config :testfleet, TestFleet.Vault,
    ciphers: [
      default:
        {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key), iv_length: 12}
    ]

  host = System.get_env("PHX_HOST") || "example.com"

  config :testfleet, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :testfleet, TestFleetWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :testfleet, TestFleetWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :testfleet, TestFleetWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :testfleet, TestFleet.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
