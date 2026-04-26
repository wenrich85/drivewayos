defmodule DrivewayOSWeb.Admin.BrandingLive do
  @moduledoc """
  Tenant admin → branding settings at `{slug}.lvh.me/admin/branding`.

  Lets the operator change every Branding-helper-visible field in
  one place: display name, support contact info, primary color,
  logo URL, timezone. Writes through the existing `Tenant.update`
  action; the LV always operates on `socket.assigns.current_tenant`
  so cross-tenant tampering is impossible by construction.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      socket.assigns.current_customer.role != :admin ->
        {:ok, push_navigate(socket, to: ~p"/")}

      true ->
        {:ok,
         socket
         |> assign(:page_title, "Branding")
         |> assign(:errors, %{})
         |> assign(:flash_msg, nil)}
    end
  end

  @impl true
  def handle_event("submit", %{"tenant" => params}, socket) do
    tenant = socket.assigns.current_tenant

    attrs =
      %{
        display_name: params["display_name"],
        support_email: params["support_email"],
        support_phone: params["support_phone"],
        primary_color_hex: params["primary_color_hex"],
        logo_url: params["logo_url"],
        timezone: params["timezone"]
      }
      # Drop blank optional fields so we don't write empty-string
      # over a previously-meaningful value.
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Map.new()

    case tenant
         |> Ash.Changeset.for_update(:update, attrs)
         |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        DrivewayOS.Platform.log_audit!(%{
          action: :tenant_branding_updated,
          tenant_id: tenant.id,
          target_type: "Tenant",
          target_id: tenant.id,
          payload: %{"changed_fields" => attrs |> Map.keys() |> Enum.map(&to_string/1)}
        })

        {:noreply,
         socket
         |> assign(:current_tenant, updated)
         |> assign(:errors, %{})
         |> assign(:flash_msg, "Saved.")}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        {:noreply, assign(socket, :errors, errors_to_map(errors))}

      {:error, _} ->
        {:noreply, assign(socket, :errors, %{base: "Could not save."})}
    end
  end

  defp errors_to_map(errors) do
    Enum.reduce(errors, %{}, fn err, acc ->
      field = Map.get(err, :field) || :base
      message = Map.get(err, :message) || inspect(err)
      Map.put(acc, field, message)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Branding</h1>
          <p class="text-sm text-base-content/70 mt-1">
            How <span class="font-semibold">{@current_tenant.display_name}</span> looks to your customers.
          </p>
        </header>

        <div :if={@flash_msg} role="alert" class="alert alert-success">
          <span class="hero-check-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@flash_msg}</span>
        </div>
        <div :if={@errors[:base]} role="alert" class="alert alert-error">
          <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <span class="text-sm">{@errors[:base]}</span>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <form id="branding-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="b-name">
                  <span class="label-text font-medium">Business name</span>
                </label>
                <input
                  id="b-name"
                  type="text"
                  name="tenant[display_name]"
                  value={@current_tenant.display_name}
                  class="input input-bordered w-full"
                  required
                />
                <p :if={@errors[:display_name]} class="text-error text-xs mt-1">
                  {@errors[:display_name]}
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label" for="b-email">
                    <span class="label-text font-medium">Support email</span>
                  </label>
                  <input
                    id="b-email"
                    type="email"
                    name="tenant[support_email]"
                    value={@current_tenant.support_email}
                    placeholder="hello@yourshop.com"
                    class="input input-bordered w-full"
                  />
                </div>
                <div>
                  <label class="label" for="b-phone">
                    <span class="label-text font-medium">Support phone</span>
                  </label>
                  <input
                    id="b-phone"
                    type="tel"
                    name="tenant[support_phone]"
                    value={@current_tenant.support_phone}
                    placeholder="+1 555 555 0100"
                    class="input input-bordered w-full"
                  />
                </div>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label" for="b-color">
                    <span class="label-text font-medium">Primary color</span>
                  </label>
                  <div class="flex items-center gap-2">
                    <span
                      :if={@current_tenant.primary_color_hex}
                      class="inline-block w-9 h-9 rounded-md border border-base-300 shrink-0"
                      style={"background-color: #{@current_tenant.primary_color_hex};"}
                      aria-hidden="true"
                    >
                    </span>
                    <input
                      id="b-color"
                      type="text"
                      name="tenant[primary_color_hex]"
                      value={@current_tenant.primary_color_hex}
                      placeholder="#0d9488"
                      class="input input-bordered w-full font-mono"
                    />
                  </div>
                  <p :if={@errors[:primary_color_hex]} class="text-error text-xs mt-1">
                    {@errors[:primary_color_hex]}
                  </p>
                </div>
                <div>
                  <label class="label" for="b-tz">
                    <span class="label-text font-medium">Timezone</span>
                  </label>
                  <input
                    id="b-tz"
                    type="text"
                    name="tenant[timezone]"
                    value={@current_tenant.timezone}
                    placeholder="America/Chicago"
                    class="input input-bordered w-full"
                  />
                </div>
              </div>

              <div>
                <label class="label" for="b-logo">
                  <span class="label-text font-medium">Logo URL</span>
                  <span class="label-text-alt text-base-content/50">Optional</span>
                </label>
                <input
                  id="b-logo"
                  type="url"
                  name="tenant[logo_url]"
                  value={@current_tenant.logo_url}
                  placeholder="https://your-cdn.com/logo.png"
                  class="input input-bordered w-full"
                />
                <p class="text-xs text-base-content/60 mt-1">
                  Direct image URL. You host the file (S3, Cloudflare R2, etc.).
                </p>
              </div>

              <button type="submit" class="btn btn-primary gap-2">
                <span class="hero-check w-5 h-5" aria-hidden="true"></span> Save
              </button>
            </form>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
