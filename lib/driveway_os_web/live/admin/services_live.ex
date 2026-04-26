defmodule DrivewayOSWeb.Admin.ServicesLive do
  @moduledoc """
  Tenant admin → service catalog CRUD at `{slug}.lvh.me/admin/services`.

  Lists every service (active + inactive), lets the operator add new
  ones, and toggle existing ones active/inactive. Customer-facing
  booking form only shows active services.

  V1 keeps it deliberately narrow: no Stripe-product sync (booking
  uses inline `price_data`), no per-vehicle pricing matrix, no
  drag-to-reorder. All V2.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

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
         |> assign(:page_title, "Services")
         |> assign(:form_error, nil)
         |> load_services()}
    end
  end

  @impl true
  def handle_event("create_service", %{"service" => params}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    attrs = %{
      slug: params["slug"] |> to_string() |> String.trim() |> String.downcase(),
      name: params["name"] |> to_string() |> String.trim(),
      description: params["description"],
      base_price_cents: dollars_to_cents(params["base_price_dollars"]),
      duration_minutes: parse_int(params["duration_minutes"])
    }

    case ServiceType
         |> Ash.Changeset.for_create(:create, attrs, tenant: tenant_id)
         |> Ash.create(authorize?: false) do
      {:ok, _svc} ->
        {:noreply, socket |> assign(:form_error, nil) |> load_services()}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map(&Map.get(&1, :message, "is invalid")) |> Enum.join("; ")
        {:noreply, assign(socket, :form_error, msg)}

      {:error, _} ->
        {:noreply, assign(socket, :form_error, "Could not save service.")}
    end
  end

  def handle_event("toggle_active", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case Ash.get(ServiceType, id, tenant: tenant_id, authorize?: false) do
      {:ok, %ServiceType{} = svc} ->
        action = if svc.active, do: :archive, else: :reactivate

        svc
        |> Ash.Changeset.for_update(action, %{})
        |> Ash.update!(authorize?: false, tenant: tenant_id)

        {:noreply, load_services(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # --- Private ---

  defp load_services(socket) do
    tenant_id = socket.assigns.current_tenant.id

    services =
      ServiceType
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.Query.sort(sort_order: :asc, name: :asc)
      |> Ash.read!(authorize?: false)

    assign(socket, :services, services)
  end

  defp dollars_to_cents(nil), do: nil

  defp dollars_to_cents(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _} -> round(n * 100)
      _ -> nil
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp fmt_price(cents), do: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Services</h1>
            <p class="text-base-content/70 text-sm">
              What you offer + what you charge.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Add a service</h2>

            <div :if={@form_error} class="alert alert-error text-sm">{@form_error}</div>

            <form
              id="new-service-form"
              phx-submit="create_service"
              class="grid grid-cols-1 md:grid-cols-6 gap-2 mt-2"
            >
              <input
                type="text"
                name="service[name]"
                placeholder="Express Detail"
                class="input input-bordered md:col-span-3"
                required
              />
              <input
                type="text"
                name="service[slug]"
                placeholder="express-detail"
                class="input input-bordered md:col-span-3"
                required
              />
              <textarea
                name="service[description]"
                placeholder="Quick spot clean…"
                rows="2"
                class="textarea textarea-bordered md:col-span-6"
              ></textarea>
              <input
                type="number"
                step="0.01"
                min="0"
                name="service[base_price_dollars]"
                placeholder="$"
                class="input input-bordered md:col-span-3"
                required
              />
              <input
                type="number"
                min="1"
                step="5"
                name="service[duration_minutes]"
                placeholder="Min"
                class="input input-bordered md:col-span-3"
                required
              />
              <button type="submit" class="btn btn-primary md:col-span-6">Add service</button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Your services</h2>

            <div :if={@services == []} class="text-center py-6 text-base-content/60">
              No services yet.
            </div>

            <ul :if={@services != []} class="divide-y divide-base-200">
              <li :for={s <- @services} class="py-3 flex items-center justify-between gap-3 flex-wrap">
                <div class="flex-1 min-w-0">
                  <div class="font-semibold flex items-center gap-2">
                    <span>{s.name}</span>
                    <span :if={not s.active} class="badge badge-ghost badge-sm">Inactive</span>
                  </div>
                  <div class="text-sm text-base-content/70">
                    {fmt_price(s.base_price_cents)} · {s.duration_minutes} min
                  </div>
                  <div :if={s.description} class="text-xs text-base-content/60 mt-1">
                    {s.description}
                  </div>
                </div>
                <button
                  phx-click="toggle_active"
                  phx-value-id={s.id}
                  class={"btn btn-sm #{if s.active, do: "btn-ghost", else: "btn-success"}"}
                >
                  {if s.active, do: "Deactivate", else: "Activate"}
                </button>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
