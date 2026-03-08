defmodule SolarObservations.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SolarObservationsWeb.Telemetry,
      SolarObservations.Repo,
      {DNSCluster, query: Application.get_env(:solar_observations, :dns_cluster_query) || :ignore},

      {SolarObservations.Workers.MountWorker,
       Application.get_env(:solar_observations, SolarObservations.Workers.MountWorker)},

      {Phoenix.PubSub, name: SolarObservations.PubSub},
      SolarObservationsWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: SolarObservations.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SolarObservationsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
