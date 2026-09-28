defmodule TestFleet.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TestFleetWeb.Telemetry,
      TestFleet.Vault,
      TestFleet.Repo,
      {Oban, Application.fetch_env!(:testfleet, Oban)},
      {DNSCluster, query: Application.get_env(:testfleet, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: TestFleet.PubSub},
      {Registry, keys: :unique, name: TestFleet.Execution.Registry},
      # Before the run processes that use them, so they stop after them.
      {Task.Supervisor, name: TestFleet.Execution.TaskSupervisor},
      TestFleet.Execution.PullCoordinator,
      {DynamicSupervisor, name: TestFleet.Execution.Supervisor, strategy: :one_for_one}
    ]

    # Tests start their own dispatcher, with a fake engine.
    dispatcher =
      if Application.get_env(:testfleet, TestFleet.Execution.Dispatcher)[:start] == false,
        do: [],
        else: [TestFleet.Execution.Dispatcher, TestFleet.Execution.Reconciler]

    # Start to serve requests, typically the last entry
    children = children ++ dispatcher ++ [TestFleetWeb.Endpoint]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TestFleet.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TestFleetWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
