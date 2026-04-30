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

# DNS resolver mock — used by Platform.verify_custom_domain so
# tests don't actually hit the resolver. Defaults to a permissive
# stub that returns no records (the test fails verification by
# default; tests that need success set explicit expectations).
Mox.defmock(DrivewayOS.Platform.DnsResolverMock,
  for: DrivewayOS.Platform.DnsResolver
)

Application.put_env(:driveway_os, :dns_resolver, DrivewayOS.Platform.DnsResolverMock)

# SMS client mock. Tests that need to assert on outgoing SMS
# expectations explicitly (Mox.expect/3); other tests fall through
# to a default stub that returns a synthetic success.
Mox.defmock(DrivewayOS.Notifications.SmsClientMock,
  for: DrivewayOS.Notifications.SmsClient
)

Application.put_env(:driveway_os, :sms_client, DrivewayOS.Notifications.SmsClientMock)

# Postmark client mock — used by Postmark.provision/2 so tests don't
# hit the real Postmark API. Tests that need to assert on server
# creation set explicit expectations via Mox.expect/3.
Mox.defmock(DrivewayOS.Notifications.PostmarkClient.Mock,
  for: DrivewayOS.Notifications.PostmarkClient
)

Application.put_env(:driveway_os, :postmark_client, DrivewayOS.Notifications.PostmarkClient.Mock)
