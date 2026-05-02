defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  @doc """
  Returns Mailer config tuned to the given tenant. Tenants with a
  Postmark API key on file get a Swoosh.Adapters.Postmark config
  scoped to their server; tenants without one fall back to the
  default Mailer config (shared SMTP).

  Pass the result as the second argument to `Mailer.deliver/2`:

      DrivewayOS.Mailer.deliver(email, DrivewayOS.Mailer.for_tenant(tenant))
  """
  @spec for_tenant(DrivewayOS.Platform.Tenant.t()) :: keyword()
  def for_tenant(%DrivewayOS.Platform.Tenant{postmark_api_key: key})
      when is_binary(key) and key != "" do
    [
      adapter: Swoosh.Adapters.Postmark,
      api_key: key
    ]
  end

  def for_tenant(_tenant), do: []
end
