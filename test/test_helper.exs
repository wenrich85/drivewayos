# Boot Wallaby + start its supervision tree so browser tests can
# spawn ChromeDriver sessions. No-op if `wallaby` isn't loaded.
if Code.ensure_loaded?(Wallaby) do
  {:ok, _} = Application.ensure_all_started(:wallaby)
end

# Skip browser-tagged tests by default — opt in with
# `mix test --include browser`. Keeps the regular suite fast and
# keeps CI from breaking when ChromeDriver isn't installed.
ExUnit.start(exclude: [:browser])
Ecto.Adapters.SQL.Sandbox.mode(DrivewayOS.Repo, :manual)

# Mox-backed mock for the Stripe API. Tests that touch billing
# expect this to be defined; tests that don't can ignore it.
Mox.defmock(DrivewayOS.Billing.StripeClientMock,
  for: DrivewayOS.Billing.StripeClient
)

Application.put_env(:driveway_os, :stripe_client, DrivewayOS.Billing.StripeClientMock)
