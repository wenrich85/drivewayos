defmodule DrivewayOSWeb.ResendOnboardingController do
  @moduledoc """
  Onboarding entry point for Resend — `GET /onboarding/resend/start`.

  Mirrors PostmarkOnboardingController's shape exactly. API-first,
  no callback step — provision runs synchronously here.

  Note: `Resend.provision/2` returns `{:ok, tenant}` where `tenant`
  is the ORIGINAL unmodified struct (Resend credentials live on
  EmailConnection, not on Tenant). The controller does NOT reach
  into the returned tenant for any Resend-specific fields — it
  logs `:provisioned` with an empty metadata map.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Onboarding.Providers.Resend

  plug DrivewayOSWeb.Plugs.RequireAdminCustomer

  def start(conn, _params) do
    tenant = conn.assigns.current_tenant
    :ok = Affiliate.log_event(tenant, :resend, :click, %{wizard_step: "email"})

    case Resend.provision(tenant, %{}) do
      {:ok, _updated} ->
        :ok = Affiliate.log_event(tenant, :resend, :provisioned, %{})
        redirect(conn, to: "/admin/onboarding")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Resend setup failed: #{inspect(reason)}")
        |> redirect(to: "/admin/onboarding")
    end
  end
end
