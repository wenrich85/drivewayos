defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  @doc """
  Returns Mailer config tuned to the given tenant. Tenants with a
  Postmark API key on file get a Swoosh.Adapters.Postmark config
  scoped to their server; tenants without one fall back to the
  default Mailer config (shared SMTP).

  In test/dev (`config :swoosh, :api_client, false`), the override
  is suppressed regardless of credentials so the configured
  Test/Local adapter keeps capturing sends — Postmark's adapter
  needs a real HTTP client and would raise.

  Pass the result as the second argument to `Mailer.deliver/2`:

      DrivewayOS.Mailer.deliver(email, DrivewayOS.Mailer.for_tenant(tenant))
  """
  @spec for_tenant(DrivewayOS.Platform.Tenant.t()) :: keyword()
  def for_tenant(%DrivewayOS.Platform.Tenant{postmark_api_key: key})
      when is_binary(key) and key != "" do
    if Application.get_env(:swoosh, :api_client) do
      [adapter: Swoosh.Adapters.Postmark, api_key: key]
    else
      []
    end
  end

  def for_tenant(_tenant), do: []
end
