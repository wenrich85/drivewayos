defmodule DrivewayOSWeb.Plugs.LoadTenant do
  @moduledoc """
  Subdomain-based tenant resolution. Runs early in the `:browser`
  pipeline (right after `:fetch_session`) on every request.

  Reads `conn.host` and classifies it:

      lvh.me / drivewayos.com         → :marketing
      www.lvh.me                      → :marketing
      admin.lvh.me                    → :platform_admin
      {slug}.lvh.me                   → :tenant (load + assign)
      <verified custom domain>        → :tenant (load + assign)
      anything-else.<platform_host>   → 404
      unknown host                    → 404

  Side effects on success in the `:tenant` branch:

    * `conn.assigns[:tenant_context] = :tenant`
    * `conn.assigns[:current_tenant] = %Tenant{}`
    * `put_session(conn, :tenant_id, tenant.id)` — so a LiveView's
      on_mount hook can re-load without an extra DB roundtrip per
      mount.

  404 cases halt the conn with a minimal text response. They never
  leak whether the tenant doesn't exist vs is archived — both look
  the same to the caller.
  """
  import Plug.Conn

  alias DrivewayOS.Platform

  @platform_subdomains ~w(www)

  # Hosts that always resolve to the marketing context regardless of
  # `:platform_host`. `localhost` and `127.0.0.1` are dev/test
  # conveniences so a developer can hit the marketing page at
  # `http://localhost:4000` without having to know about `lvh.me`.
  # In prod these names aren't reachable from the public internet, so
  # they're harmless to leave on.
  @marketing_aliases ~w(localhost 127.0.0.1)

  def init(opts), do: opts

  def call(conn, _opts) do
    platform_host = Application.fetch_env!(:driveway_os, :platform_host)

    case classify(conn.host, platform_host) do
      :marketing ->
        conn
        |> assign(:tenant_context, :marketing)
        |> assign(:current_tenant, nil)
        |> put_session(:tenant_context, :marketing)

      :platform_admin ->
        conn
        |> assign(:tenant_context, :platform_admin)
        |> assign(:current_tenant, nil)
        |> put_session(:tenant_context, :platform_admin)

      {:tenant, slug} ->
        case Platform.get_tenant_by_slug(slug) do
          {:ok, %{status: :suspended} = tenant} ->
            halt_503(conn, tenant)

          {:ok, tenant} ->
            assign_tenant(conn, tenant)

          _ ->
            halt_404(conn)
        end

      :unknown ->
        # Last chance: maybe this is a tenant's custom domain. Hits
        # the DB on every unknown-host request — fine at our scale,
        # but add a small process-dict cache here when it gets hot.
        case Platform.get_tenant_by_custom_hostname(conn.host) do
          {:ok, tenant} -> assign_tenant(conn, tenant)
          _ -> halt_404(conn)
        end
    end
  end

  defp assign_tenant(conn, tenant) do
    conn
    |> assign(:tenant_context, :tenant)
    |> assign(:current_tenant, tenant)
    |> put_session(:tenant_id, tenant.id)
    |> put_session(:tenant_context, :tenant)
  end

  # --- Private ---

  defp classify(host, platform_host) do
    cond do
      host == platform_host ->
        :marketing

      host in @marketing_aliases ->
        :marketing

      String.ends_with?(host, "." <> platform_host) ->
        sub = String.replace_suffix(host, "." <> platform_host, "")

        cond do
          sub == "admin" -> :platform_admin
          sub in @platform_subdomains -> :marketing
          # If a subdomain has further dots (e.g. "a.b.lvh.me") treat
          # it as unknown — we don't support nested subdomains.
          String.contains?(sub, ".") -> :unknown
          true -> {:tenant, sub}
        end

      true ->
        # Host doesn't match the platform host at all. Could be a
        # custom domain (Phase 7) or somebody hitting the IP. Return
        # :unknown for now; custom-domain support adds another branch.
        :unknown
    end
  end

  defp halt_404(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Not found")
    |> halt()
  end

  # Suspended tenants get a friendly 503 page that names the
  # tenant + tells the customer to come back later. 503 (not 404)
  # is the correct semantic — the resource exists, it's just
  # temporarily unavailable.
  defp halt_503(conn, tenant) do
    body = """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>#{html_escape(tenant.display_name)} is paused</title>
        <style>
          body { font-family: system-ui, -apple-system, sans-serif; background: #f4f4f5; color: #18181b; margin: 0; padding: 0; }
          main { max-width: 32rem; margin: 6rem auto; padding: 2rem; background: white; border-radius: .75rem; box-shadow: 0 1px 3px rgba(0,0,0,.08); text-align: center; }
          h1 { margin: 0 0 .5rem; font-size: 1.75rem; }
          p { color: #52525b; line-height: 1.6; }
          .badge { display: inline-block; background: #fef9c3; color: #854d0e; font-size: .75rem; padding: .15rem .6rem; border-radius: 999px; margin-bottom: 1rem; }
        </style>
      </head>
      <body>
        <main>
          <span class="badge">Paused</span>
          <h1>#{html_escape(tenant.display_name)} isn't taking bookings right now.</h1>
          <p>This shop is temporarily on hold. If you're a customer with an existing booking, your wash is still scheduled — please check back later or reach out to the shop directly.</p>
        </main>
      </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(503, body)
    |> halt()
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
