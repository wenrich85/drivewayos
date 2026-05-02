defmodule DrivewayOSWeb.EmailVerificationController do
  @moduledoc """
  Customer clicks the link in a "verify your email" email; we
  validate the token, flip `email_verified_at` on the Customer,
  and bounce them to /.

  Tenant resolution: requires `current_tenant` (the link is on the
  tenant subdomain). The token also carries a `tenant` claim that
  AshAuth verifies, so a token from tenant A can never confirm
  someone on tenant B.
  """
  use DrivewayOSWeb, :controller

  alias DrivewayOS.Notifications.EmailVerification

  def verify(conn, %{"token" => token}) do
    case conn.assigns[:current_tenant] do
      nil ->
        send_resp(conn, 400, "Tenant not found.")

      tenant ->
        case EmailVerification.verify_token(token, tenant) do
          {:ok, customer} ->
            customer
            |> Ash.Changeset.for_update(:verify_email, %{})
            |> Ash.update!(authorize?: false, tenant: tenant.id)

            conn
            |> put_flash(:info, "Email verified.")
            |> redirect(to: ~p"/")

          _ ->
            send_resp(conn, 400, "Invalid or expired verification link.")
        end
    end
  end

  def verify(conn, _), do: send_resp(conn, 400, "Missing token.")

  @doc """
  POST /auth/customer/resend-verification — re-send the
  verification email to the signed-in customer. No-ops silently
  if not signed in or already verified.
  """
  def resend(conn, _params) do
    with %{} = tenant <- conn.assigns[:current_tenant],
         %{} = customer <- conn.assigns[:current_customer],
         true <- is_nil(customer.email_verified_at) do
      send_verification_email(tenant, customer, conn)
    end

    conn
    |> put_flash(:info, "Verification email sent.")
    |> redirect(to: ~p"/")
  end

  @doc """
  Mint + send a verification email. Public so other code paths
  (post-register, admin "resend") can call it directly.
  """
  def send_verification_email(tenant, customer, conn) do
    token = EmailVerification.mint_token(customer)
    link = build_link(conn, token)

    tenant
    |> EmailVerification.build_email(customer, link)
    |> DrivewayOS.Mailer.deliver(DrivewayOS.Mailer.for_tenant(tenant))
  rescue
    _ -> :error
  end

  defp build_link(conn, token) do
    "#{Phoenix.Controller.endpoint_module(conn).url()}/auth/customer/verify-email?token=#{token}"
    # endpoint_module/1 returns http://localhost in dev (no host
    # subdomain) — fall back to manual construction with conn.host.
  rescue
    _ ->
      scheme = if conn.scheme == :https, do: "https", else: "http"

      port_suffix =
        case conn.port do
          80 -> ""
          443 -> ""
          p -> ":#{p}"
        end

      "#{scheme}://#{conn.host}#{port_suffix}/auth/customer/verify-email?token=#{token}"
  end
end
