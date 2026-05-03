defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  @doc """
  Returns Mailer config tuned to the given tenant.

  Routing precedence:
    1. Active `Platform.EmailConnection{provider: :resend}` →
       `Swoosh.Adapters.Resend` config scoped to the tenant's api_key.
    2. `tenant.postmark_api_key` set → `Swoosh.Adapters.Postmark`
       config scoped to the tenant's server.
    3. Neither → `[]` (falls through to the platform default Mailer
       config — typically shared SMTP).

  In test/dev (`config :swoosh, :api_client, false`), the override
  is suppressed regardless of credentials so the configured
  Test/Local adapter keeps capturing sends — Postmark/Resend
  adapters need a real HTTP client and would raise.

  Pass the result as the second argument to `Mailer.deliver/2`:

      DrivewayOS.Mailer.deliver(email, DrivewayOS.Mailer.for_tenant(tenant))
  """
  @spec for_tenant(Tenant.t()) :: keyword()
  def for_tenant(%Tenant{} = tenant) do
    cond do
      not Application.get_env(:swoosh, :api_client) ->
        []

      conn = active_resend_connection(tenant) ->
        [adapter: Swoosh.Adapters.Resend, api_key: conn.api_key]

      is_binary(tenant.postmark_api_key) and tenant.postmark_api_key != "" ->
        [adapter: Swoosh.Adapters.Postmark, api_key: tenant.postmark_api_key]

      true ->
        []
    end
  end

  defp active_resend_connection(%Tenant{id: tenant_id}) do
    case Platform.get_active_email_connection(tenant_id, :resend) do
      {:ok, conn} -> conn
      _ -> nil
    end
  end
end
