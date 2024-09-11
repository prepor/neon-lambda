defmodule NeonLambda.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NeonLambdaWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:neon_lambda, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: NeonLambda.PubSub},
      {DynamicSupervisor, name: NeonLambda.Workers, strategy: :one_for_one},
      NeonLambda.Balancer,
      {Bandit, plug: NeonLambda.Plug, port: 3010},
      NeonLambda.Scaler,
      NeonLambdaWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_all, name: NeonLambda.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NeonLambdaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
