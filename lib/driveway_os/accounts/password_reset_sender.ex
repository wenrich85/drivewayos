defmodule DrivewayOS.Accounts.PasswordResetSender do
  @moduledoc """
  AshAuthentication password-reset sender. Receives `(user, token,
  opts)` from the framework when a customer requests a reset and
  hands off to our PasswordResetEmail template.

  Tenant-host context: the user is loaded under a tenant (the
  multitenancy filter ran during the request action), so we can
  pull tenant_id from the row and build a tenant-specific URL.
  """
  use AshAuthentication.Sender

  alias DrivewayOS.Mailer
  alias DrivewayOS.Notifications.PasswordResetEmail
  alias DrivewayOS.Platform.Tenant

  @impl true
  def send(user, token, _opts) do
    case Ash.get(Tenant, user.tenant_id, authorize?: false) do
      {:ok, tenant} ->
        link_url = build_url(tenant, token)

        tenant
        |> PasswordResetEmail.reset_link(user, link_url)
        |> Mailer.deliver()

      _ ->
        :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp build_url(tenant, token) do
    host = Application.get_env(:driveway_os, :platform_host, "drivewayos.com")
    http_opts = Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)[:http] || []
    port = Keyword.get(http_opts, :port)

    {scheme, port_suffix} =
      cond do
        host == "lvh.me" -> {"http", ":#{port || 4000}"}
        port in [nil, 80, 443] -> {"https", ""}
        true -> {"https", ":#{port}"}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}/reset-password/#{token}"
  end
end
