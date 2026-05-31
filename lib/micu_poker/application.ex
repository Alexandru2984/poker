defmodule MicuPoker.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MicuPokerWeb.Telemetry,
      MicuPoker.Repo,
      {DNSCluster, query: Application.get_env(:micu_poker, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: MicuPoker.PubSub},
      {Registry, keys: :unique, name: MicuPoker.TableRegistry},
      MicuPoker.Poker.TableSupervisor,
      # Start the Finch HTTP client for sending emails
      {Finch, name: MicuPoker.Finch},
      # Start a worker by calling: MicuPoker.Worker.start_link(arg)
      # {MicuPoker.Worker, arg},
      # Start to serve requests, typically the last entry
      MicuPokerWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: MicuPoker.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    MicuPokerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
