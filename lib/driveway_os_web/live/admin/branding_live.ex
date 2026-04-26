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
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-2xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Branding</h1>
            <p class="text-base-content/70 text-sm">
              How {@current_tenant.display_name} looks to your customers.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <div :if={@flash_msg} class="alert alert-success text-sm">{@flash_msg}</div>
        <div :if={@errors[:base]} class="alert alert-error text-sm">{@errors[:base]}</div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <form id="branding-form" phx-submit="submit" class="space-y-4">
              <div>
                <label class="label" for="b-name">
                  <span class="label-text">Business name</span>
                </label>
                <input
                  id="b-name"
                  type="text"
                  name="tenant[display_name]"
                  value={@current_tenant.display_name}
                  class="input input-bordered w-full"
                  required
                />
                <p :if={@errors[:display_name]} class="text-error text-sm mt-1">
                  {@errors[:display_name]}
                </p>
              </div>

              <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
                <div>
                  <label class="label" for="b-email">
                    <span class="label-text">Support email</span>
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
                    <span class="label-text">Support phone</span>
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
                    <span class="label-text">Primary color</span>
                  </label>
                  <input
                    id="b-color"
                    type="text"
                    name="tenant[primary_color_hex]"
                    value={@current_tenant.primary_color_hex}
                    placeholder="#0d9488"
                    class="input input-bordered w-full font-mono"
                  />
                  <p :if={@errors[:primary_color_hex]} class="text-error text-sm mt-1">
                    {@errors[:primary_color_hex]}
                  </p>
                </div>
                <div>
                  <label class="label" for="b-tz">
                    <span class="label-text">Timezone</span>
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
                  <span class="label-text">Logo URL</span>
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
                  Direct image URL. Hosting your own file (S3, Cloudflare R2, etc.).
                </p>
              </div>

              <button type="submit" class="btn btn-primary">Save</button>
            </form>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
