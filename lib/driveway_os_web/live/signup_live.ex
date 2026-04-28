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
       |> assign(:slug_status, :empty)
       |> assign(:slug_auto?, true)
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

  # phx-change driver. Fires on every form keystroke.
  # Two pieces of live feedback:
  #   1. Slug availability — debounced via the input's phx-debounce
  #   2. Auto-suggested slug from display_name when the slug field
  #      hasn't been touched manually yet (slug_auto? = true)
  @impl true
  def handle_event("validate", %{"signup" => params, "_target" => target}, socket) do
    slug_field_touched? = target == ["signup", "slug"]

    # When the user types in the slug field directly, lock auto-suggest.
    # Otherwise, derive from display_name as long as auto is still on.
    {slug, slug_auto?} =
      cond do
        slug_field_touched? ->
          {params["slug"], false}

        socket.assigns.slug_auto? ->
          {Platform.slugify(params["display_name"]), true}

        true ->
          {params["slug"], socket.assigns.slug_auto?}
      end

    params = Map.put(params, "slug", slug)
    slug_status = check_slug_status(slug)

    {:noreply,
     socket
     |> assign(:form, params)
     |> assign(:slug_auto?, slug_auto?)
     |> assign(:slug_status, slug_status)}
  end

  defp check_slug_status(slug) do
    case String.trim(slug || "") do
      "" -> :empty
      _ -> Platform.slug_available?(slug)
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

          <form
            id="signup-form"
            phx-submit="submit"
            phx-change="validate"
            class="space-y-4"
          >
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
                phx-debounce="200"
              />
              <p :if={@errors[:display_name]} class="text-error text-sm mt-1">
                {@errors[:display_name]}
              </p>
            </div>

            <div>
              <label class="label" for="signup-slug">
                <span class="label-text">Your URL</span>
                <span :if={@slug_auto?} class="label-text-alt text-base-content/50">
                  auto-filled — edit to override
                </span>
              </label>
              <div class="join w-full">
                <input
                  id="signup-slug"
                  type="text"
                  name="signup[slug]"
                  value={@form["slug"]}
                  placeholder="acme-wash"
                  class={
                    "input input-bordered join-item w-full " <>
                      slug_input_class(@slug_status)
                  }
                  required
                  phx-debounce="300"
                />
                <span class="join-item btn btn-ghost no-animation cursor-default text-base-content/70">
                  .{slug_host()}
                </span>
              </div>

              <%!-- Live availability feedback. Empty state hides the
                   row so the form doesn't render an unfilled chip. --%>
              <div :if={@slug_status != :empty} class="mt-1.5">
                <%= case @slug_status do %>
                  <% :ok -> %>
                    <p class="text-success text-sm flex items-center gap-1">
                      <span class="hero-check-circle w-4 h-4" aria-hidden="true"></span>
                      <span>
                        <span class="font-medium">{@form["slug"]}.{slug_host()}</span>
                        is available
                      </span>
                    </p>
                  <% {:error, :too_short} -> %>
                    <p class="text-base-content/60 text-sm">
                      A few more letters — minimum 3.
                    </p>
                  <% {:error, :bad_format} -> %>
                    <p class="text-error text-sm flex items-center gap-1">
                      <span class="hero-x-circle w-4 h-4" aria-hidden="true"></span>
                      Letters, numbers, and dashes only. Can't start or end with a dash.
                    </p>
                  <% {:error, :reserved} -> %>
                    <p class="text-error text-sm flex items-center gap-1">
                      <span class="hero-x-circle w-4 h-4" aria-hidden="true"></span>
                      That word is reserved for the platform — pick something else.
                    </p>
                  <% {:error, :taken} -> %>
                    <p class="text-error text-sm flex items-center gap-1">
                      <span class="hero-x-circle w-4 h-4" aria-hidden="true"></span>
                      Another shop already has that URL.
                    </p>
                <% end %>
              </div>
              <p :if={@errors[:slug]} class="text-error text-sm mt-1">
                {@errors[:slug]}
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
                phx-debounce="200"
              />

              <%!-- Live strength checklist. Renders as soon as the
                   user starts typing; each line flips from muted to
                   success-green as the rule is satisfied. --%>
              <ul
                :if={(@form["admin_password"] || "") != ""}
                class="grid grid-cols-2 gap-x-2 gap-y-0.5 text-xs mt-1.5"
              >
                <li :for={{label, ok?} <- password_rules(@form["admin_password"])}
                    class={if ok?, do: "text-success", else: "text-base-content/60"}
                >
                  <span class={if ok?, do: "hero-check w-3 h-3 inline align-text-top", else: "hero-minus w-3 h-3 inline align-text-top"}
                        aria-hidden="true">
                  </span>
                  {label}
                </li>
              </ul>
              <p :if={(@form["admin_password"] || "") == ""} class="text-xs text-base-content/60 mt-1">
                10+ chars, with one upper, one lower, one digit.
              </p>
              <p :if={@errors[:password]} class="text-error text-sm mt-1">
                {@errors[:password]}
              </p>
            </div>

            <button
              type="submit"
              disabled={@slug_status != :ok}
              class="btn btn-primary w-full"
            >
              Create my shop
            </button>
            <p class="text-xs text-base-content/50 text-center">
              You'll land on your admin dashboard with a quick setup checklist.
            </p>
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

  # Display host for the URL preview — matches the platform-host
  # config so dev shows ".lvh.me" and prod shows ".drivewayos.com".
  defp slug_host do
    Application.get_env(:driveway_os, :platform_host, "drivewayos.com")
  end

  # Tints the slug input border green/red so the operator gets
  # signal even before reading the message below.
  defp slug_input_class(:ok), do: "input-success"
  defp slug_input_class({:error, :too_short}), do: ""
  defp slug_input_class({:error, _}), do: "input-error"
  defp slug_input_class(_), do: ""

  # The password resource enforces these rules on submit; we mirror
  # them here purely for live feedback. Order is the order the list
  # renders.
  defp password_rules(nil), do: password_rules("")

  defp password_rules(password) when is_binary(password) do
    [
      {"10+ characters", String.length(password) >= 10},
      {"One uppercase", String.match?(password, ~r/[A-Z]/)},
      {"One lowercase", String.match?(password, ~r/[a-z]/)},
      {"One digit", String.match?(password, ~r/[0-9]/)}
    ]
  end
end
