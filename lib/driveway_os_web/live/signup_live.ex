defmodule DrivewayOSWeb.SignupLive do
  @moduledoc """
  Tenant signup form. Lives at `/signup` on the marketing host
  (`drivewayos.com`). Submitting calls
  `DrivewayOS.Platform.provision_tenant/1` to create a Tenant + the
  first admin Customer atomically, then redirects to the new tenant
  subdomain.

  Hitting `/signup` from a tenant subdomain bounces back to the
  tenant landing page — that subdomain already has a tenant, no
  signup needed.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook

  alias DrivewayOS.Platform

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns[:current_tenant] do
      {:ok, push_navigate(socket, to: ~p"/")}
    else
      {:ok,
       socket
       |> assign(:page_title, "Start your shop")
       |> assign(:errors, %{})
       |> assign(:form, %{
         "slug" => "",
         "display_name" => "",
         "admin_email" => "",
         "admin_name" => "",
         "admin_password" => "",
         "admin_phone" => ""
       })}
    end
  end

  @impl true
  def handle_event("submit", %{"signup" => params}, socket) do
    attrs = %{
      slug: params["slug"] |> to_string() |> String.trim() |> String.downcase(),
      display_name: params["display_name"] |> to_string() |> String.trim(),
      admin_email: params["admin_email"] |> to_string() |> String.trim() |> String.downcase(),
      admin_name: params["admin_name"] |> to_string() |> String.trim(),
      admin_password: params["admin_password"] |> to_string(),
      admin_phone: params["admin_phone"] |> to_string() |> String.trim()
    }

    case Platform.provision_tenant(attrs) do
      {:ok, %{tenant: tenant, admin: admin}} ->
        {:noreply, redirect(socket, external: tenant_admin_signed_in_url(tenant, admin))}

      {:error, :reserved_slug} ->
        {:noreply,
         socket
         |> assign(:errors, %{slug: "is reserved or unavailable"})
         |> assign(:form, params)}

      {:error, %Ash.Error.Invalid{} = e} ->
        {:noreply,
         socket
         |> assign(:errors, ash_errors_to_map(e))
         |> assign(:form, params)}

      {:error, _other} ->
        {:noreply,
         socket
         |> assign(:errors, %{base: "Could not create your shop. Try a different slug."})
         |> assign(:form, params)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center bg-base-200 px-4 py-12">
      <div class="card w-full max-w-lg bg-base-100 shadow-lg">
        <div class="card-body">
          <h1 class="card-title text-3xl">Start your shop</h1>
          <p class="text-base-content/70 mb-4">
            Spin up a branded mobile-detailing storefront on DrivewayOS.
            Takes a couple of minutes.
          </p>

          <div :if={@errors[:base]} class="alert alert-error text-sm">
            {@errors[:base]}
          </div>

          <form id="signup-form" phx-submit="submit" class="space-y-4">
            <div>
              <label class="label" for="signup-slug">
                <span class="label-text">URL slug</span>
              </label>
              <div class="join w-full">
                <input
                  id="signup-slug"
                  type="text"
                  name="signup[slug]"
                  value={@form["slug"]}
                  placeholder="acme-wash"
                  class="input input-bordered join-item w-full"
                  required
                />
                <span class="join-item btn btn-ghost no-animation cursor-default">
                  .drivewayos.com
                </span>
              </div>
              <p :if={@errors[:slug]} class="text-error text-sm mt-1">
                {@errors[:slug]}
              </p>
            </div>

            <div>
              <label class="label" for="signup-display-name">
                <span class="label-text">Business name</span>
              </label>
              <input
                id="signup-display-name"
                type="text"
                name="signup[display_name]"
                value={@form["display_name"]}
                placeholder="Acme Mobile Wash"
                class="input input-bordered w-full"
                required
              />
              <p :if={@errors[:display_name]} class="text-error text-sm mt-1">
                {@errors[:display_name]}
              </p>
            </div>

            <div class="divider text-sm">Owner account</div>

            <div>
              <label class="label" for="signup-admin-name">
                <span class="label-text">Your name</span>
              </label>
              <input
                id="signup-admin-name"
                type="text"
                name="signup[admin_name]"
                value={@form["admin_name"]}
                class="input input-bordered w-full"
                required
              />
            </div>

            <div>
              <label class="label" for="signup-admin-email">
                <span class="label-text">Email</span>
              </label>
              <input
                id="signup-admin-email"
                type="email"
                name="signup[admin_email]"
                value={@form["admin_email"]}
                class="input input-bordered w-full"
                required
              />
              <p :if={@errors[:email]} class="text-error text-sm mt-1">
                {@errors[:email]}
              </p>
            </div>

            <div>
              <label class="label" for="signup-admin-phone">
                <span class="label-text">Phone (optional)</span>
              </label>
              <input
                id="signup-admin-phone"
                type="tel"
                name="signup[admin_phone]"
                value={@form["admin_phone"]}
                placeholder="+1 512 555 0100"
                class="input input-bordered w-full"
              />
            </div>

            <div>
              <label class="label" for="signup-admin-password">
                <span class="label-text">Password</span>
              </label>
              <input
                id="signup-admin-password"
                type="password"
                name="signup[admin_password]"
                class="input input-bordered w-full"
                required
              />
              <p class="text-xs text-base-content/60 mt-1">
                10+ chars, at least one upper, one lower, one digit.
              </p>
              <p :if={@errors[:password]} class="text-error text-sm mt-1">
                {@errors[:password]}
              </p>
            </div>

            <button type="submit" class="btn btn-primary w-full">
              Create my shop
            </button>
          </form>
        </div>
      </div>
    </main>
    """
  end

  # --- Helpers ---

  # After provisioning, redirect through the tenant subdomain's
  # `/auth/customer/store-token` controller so the new admin lands
  # on `/admin` already signed in. LVs can't write the session
  # cookie themselves; the controller does it for us. The token
  # is a one-shot — `LoadCustomer` re-verifies signature + tenant
  # claim on every subsequent request.
  defp tenant_admin_signed_in_url(tenant, admin) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(admin)

    base = tenant_root_base_url(tenant)
    return_to = URI.encode_www_form("/admin")
    encoded_token = URI.encode_www_form(token)

    "#{base}/auth/customer/store-token?token=#{encoded_token}&return_to=#{return_to}"
  end

  defp tenant_root_base_url(tenant) do
    host = Application.get_env(:driveway_os, :platform_host, "drivewayos.com")
    http_opts = Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)[:http] || []
    port = Keyword.get(http_opts, :port)

    {scheme, port_suffix} =
      cond do
        host == "lvh.me" -> {"http", ":#{port || 4000}"}
        port in [nil, 80, 443] -> {"https", ""}
        true -> {"https", ":#{port}"}
      end

    "#{scheme}://#{tenant.slug}.#{host}#{port_suffix}"
  end

  defp ash_errors_to_map(%Ash.Error.Invalid{errors: errors}) do
    Enum.reduce(errors, %{}, fn err, acc ->
      field = Map.get(err, :field) || :base
      message = Map.get(err, :message) || inspect(err)
      Map.put(acc, field, message)
    end)
  end
end
