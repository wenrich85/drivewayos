defmodule DrivewayOS.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DrivewayOSWeb.Telemetry,
        DrivewayOS.Repo,
        {DNSCluster, query: Application.get_env(:driveway_os, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DrivewayOS.PubSub},
        DrivewayOS.RateLimiter
      ] ++
        scheduler_children() ++
        [DrivewayOSWeb.Endpoint]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: DrivewayOS.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Background workers (reminder sweeper, etc.) are skipped in test
  # so they don't fight the SQL Sandbox or fire emails. Tests drive
  # `dispatch_due_reminders/1` directly with a deterministic clock.
  defp scheduler_children do
    if Application.get_env(:driveway_os, :start_schedulers?, true) do
      [
        DrivewayOS.Notifications.ReminderScheduler,
        DrivewayOS.Scheduling.SubscriptionScheduler
      ]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    DrivewayOSWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
