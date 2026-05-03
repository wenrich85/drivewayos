defmodule DrivewayOSWeb.PostmarkOnboardingController do
  @moduledoc """
  Onboarding entry point for Postmark — `GET /onboarding/postmark/start`.

  Calls `Postmark.provision/2` synchronously (it's API-first, no
  OAuth), logs `:click` before and `:provisioned` on success via
  `Affiliate.log_event/4`. Redirects back to the wizard either way;
  errors land in flash. Mirrors Phase 1's wizard-submit shape but
  via a controller, matching the Square / Stripe / Resend pattern.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Onboarding.Affiliate
  alias DrivewayOS.Onboarding.Providers.Postmark

  plug :require_admin_customer

  def start(conn, _params) do
    tenant = conn.assigns.current_tenant
    :ok = Affiliate.log_event(tenant, :postmark, :click, %{wizard_step: "email"})

    case Postmark.provision(tenant, %{}) do
      {:ok, updated} ->
        :ok =
          Affiliate.log_event(updated, :postmark, :provisioned, %{
            server_id: updated.postmark_server_id
          })

        redirect(conn, to: "/admin/onboarding")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Postmark setup failed: #{inspect(reason)}")
        |> redirect(to: "/admin/onboarding")
    end
  end

  defp require_admin_customer(conn, _opts) do
    cust = conn.assigns[:current_customer]

    cond do
      is_nil(cust) ->
        conn |> redirect(to: "/sign-in") |> halt()

      cust.role != :admin ->
        conn |> redirect(to: "/") |> halt()

      true ->
        conn
    end
  end
end
