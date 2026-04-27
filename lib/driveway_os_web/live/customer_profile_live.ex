defmodule DrivewayOSWeb.CustomerProfileLive do
  @moduledoc """
  /me — the signed-in customer's profile + saved-data hub.

  Edit affordances are inline on the same page:

    * `:profile_mode` flips between :read and :edit (name + phone)
    * `:vehicle_form?` shows the inline "Add vehicle" form
    * `:address_form?` shows the inline "Add address" form

  Delete buttons trigger immediate destroys (no confirmation modal
  — just a `data-confirm`). All Ash calls run with the
  `current_customer.id` baked into the action args + a tenant-scoped
  query, so a malicious payload can't delete another customer's
  rows even if they guess an id (the multitenancy filter rejects it
  before it reaches the destroy callback).
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Fleet.{Address, Vehicle}
  alias DrivewayOS.Scheduling.{ServiceType, Subscription}

  require Ash.Query

  @impl true
  def mount(_params, _session, socket) do
    cond do
      is_nil(socket.assigns[:current_tenant]) ->
        {:ok, push_navigate(socket, to: ~p"/")}

      is_nil(socket.assigns[:current_customer]) ->
        {:ok, push_navigate(socket, to: ~p"/sign-in")}

      true ->
        {:ok, base_assigns(socket)}
    end
  end

  defp base_assigns(socket) do
    tenant_id = socket.assigns.current_tenant.id
    customer_id = socket.assigns.current_customer.id

    socket
    |> assign(:page_title, "Profile")
    |> assign(:vehicles, load_vehicles(customer_id, tenant_id))
    |> assign(:addresses, load_addresses(customer_id, tenant_id))
    |> assign(:subscriptions, load_subscriptions(customer_id, tenant_id))
    |> assign(:service_map, load_service_map(tenant_id))
    |> assign(:profile_mode, :read)
    |> assign(:vehicle_form?, false)
    |> assign(:address_form?, false)
    |> assign(:errors, %{})
  end

  defp load_subscriptions(customer_id, tenant_id) do
    Subscription
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp load_service_map(tenant_id) do
    case ServiceType
         |> Ash.Query.set_tenant(tenant_id)
         |> Ash.read(authorize?: false) do
      {:ok, services} -> Map.new(services, &{&1.id, &1})
      _ -> %{}
    end
  end

  defp load_vehicles(customer_id, tenant_id) do
    Vehicle
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  defp load_addresses(customer_id, tenant_id) do
    Address
    |> Ash.Query.for_read(:for_customer, %{customer_id: customer_id})
    |> Ash.Query.set_tenant(tenant_id)
    |> Ash.read!(authorize?: false)
  end

  # --- Profile edit ---

  @impl true
  def handle_event("edit_profile", _, socket) do
    {:noreply, assign(socket, :profile_mode, :edit)}
  end

  def handle_event("cancel_edit_profile", _, socket) do
    {:noreply, socket |> assign(:profile_mode, :read) |> assign(:errors, %{})}
  end

  def handle_event("save_profile", %{"profile" => params}, socket) do
    me = socket.assigns.current_customer

    case me
         |> Ash.Changeset.for_update(:update, %{
           name: params["name"],
           phone: params["phone"]
         })
         |> Ash.update(authorize?: false, tenant: socket.assigns.current_tenant.id) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:current_customer, updated)
         |> assign(:profile_mode, :read)
         |> assign(:errors, %{})}

      {:error, _} ->
        {:noreply, assign(socket, :errors, %{profile: "Couldn't save — try again."})}
    end
  end

  # --- Vehicle CRUD ---

  def handle_event("add_vehicle", _, socket) do
    {:noreply, assign(socket, :vehicle_form?, true)}
  end

  def handle_event("cancel_add_vehicle", _, socket) do
    {:noreply, socket |> assign(:vehicle_form?, false) |> assign(:errors, %{})}
  end

  def handle_event("save_vehicle", %{"vehicle" => params}, socket) do
    tenant = socket.assigns.current_tenant
    me = socket.assigns.current_customer

    attrs = %{
      customer_id: me.id,
      year: parse_int(params["year"]),
      make: params["make"],
      model: params["model"],
      color: params["color"],
      license_plate: params["license_plate"],
      nickname: params["nickname"]
    }

    case Vehicle
         |> Ash.Changeset.for_create(:add, attrs, tenant: tenant.id)
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:vehicles, load_vehicles(me.id, tenant.id))
         |> assign(:vehicle_form?, false)
         |> assign(:errors, %{})}

      {:error, _} ->
        {:noreply, assign(socket, :errors, %{vehicle: "Couldn't add — check the fields."})}
    end
  end

  def handle_event("delete_vehicle", %{"id" => id}, socket) do
    tenant = socket.assigns.current_tenant
    me = socket.assigns.current_customer

    with {:ok, v} <- Ash.get(Vehicle, id, tenant: tenant.id, authorize?: false),
         true <- v.customer_id == me.id,
         :ok <- Ash.destroy(v, authorize?: false, tenant: tenant.id) do
      {:noreply, assign(socket, :vehicles, load_vehicles(me.id, tenant.id))}
    else
      _ -> {:noreply, socket}
    end
  end

  # --- Address CRUD ---

  def handle_event("add_address", _, socket) do
    {:noreply, assign(socket, :address_form?, true)}
  end

  def handle_event("cancel_add_address", _, socket) do
    {:noreply, socket |> assign(:address_form?, false) |> assign(:errors, %{})}
  end

  def handle_event("save_address", %{"address" => params}, socket) do
    tenant = socket.assigns.current_tenant
    me = socket.assigns.current_customer

    attrs = %{
      customer_id: me.id,
      street_line1: params["street_line1"],
      street_line2: params["street_line2"],
      city: params["city"],
      state: params["state"],
      zip: params["zip"],
      nickname: params["nickname"],
      instructions: params["instructions"]
    }

    case Address
         |> Ash.Changeset.for_create(:add, attrs, tenant: tenant.id)
         |> Ash.create(authorize?: false) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:addresses, load_addresses(me.id, tenant.id))
         |> assign(:address_form?, false)
         |> assign(:errors, %{})}

      {:error, _} ->
        {:noreply, assign(socket, :errors, %{address: "Couldn't add — check the fields."})}
    end
  end

  def handle_event("delete_address", %{"id" => id}, socket) do
    tenant = socket.assigns.current_tenant
    me = socket.assigns.current_customer

    with {:ok, a} <- Ash.get(Address, id, tenant: tenant.id, authorize?: false),
         true <- a.customer_id == me.id,
         :ok <- Ash.destroy(a, authorize?: false, tenant: tenant.id) do
      {:noreply, assign(socket, :addresses, load_addresses(me.id, tenant.id))}
    else
      _ -> {:noreply, socket}
    end
  end

  # --- Subscription transitions ---

  def handle_event("pause_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :pause)

  def handle_event("resume_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :resume)

  def handle_event("cancel_subscription", %{"id" => id}, socket),
    do: transition_subscription(socket, id, :cancel)

  defp transition_subscription(socket, id, action) do
    tenant = socket.assigns.current_tenant
    me = socket.assigns.current_customer

    with {:ok, sub} <- Ash.get(Subscription, id, tenant: tenant.id, authorize?: false),
         true <- sub.customer_id == me.id,
         {:ok, _} <-
           sub
           |> Ash.Changeset.for_update(action, %{})
           |> Ash.update(authorize?: false, tenant: tenant.id) do
      {:noreply, assign(socket, :subscriptions, load_subscriptions(me.id, tenant.id))}
    else
      _ -> {:noreply, socket}
    end
  end

  # --- Helpers ---

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end
  defp parse_int(n) when is_integer(n), do: n

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-2xl mx-auto space-y-6">
        <header class="flex justify-between items-start gap-3 flex-wrap">
          <div>
            <p class="text-xs font-semibold uppercase tracking-wide text-base-content/60">
              Profile
            </p>
            <h1 class="text-3xl font-bold tracking-tight">{@current_customer.name}</h1>
          </div>
          <nav class="flex gap-1 flex-wrap">
            <.link navigate={~p"/appointments"} class="btn btn-ghost btn-sm gap-1">
              <span class="hero-calendar w-4 h-4" aria-hidden="true"></span> Appointments
            </.link>
            <.link navigate={~p"/book"} class="btn btn-primary btn-sm gap-1">
              <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Book a wash
            </.link>
            <a href="/auth/customer/sign-out" class="btn btn-ghost btn-sm gap-1">
              <span class="hero-arrow-left-on-rectangle w-4 h-4" aria-hidden="true"></span>
              Sign out
            </a>
          </nav>
        </header>

        <section
          :if={loyalty_visible?(@current_tenant, @current_customer)}
          class="card bg-primary/5 border border-primary/20 shadow-sm"
        >
          <div class="card-body p-6">
            <div class="flex items-center gap-3">
              <span class="hero-gift w-6 h-6 text-primary shrink-0" aria-hidden="true"></span>
              <div class="flex-1">
                <h2 class="font-semibold">
                  <%= if loyalty_earned?(@current_tenant, @current_customer) do %>
                    You've earned a free wash!
                  <% else %>
                    {@current_customer.loyalty_count}/{@current_tenant.loyalty_threshold} washes toward your next free one
                  <% end %>
                </h2>
                <p :if={not loyalty_earned?(@current_tenant, @current_customer)} class="text-sm text-base-content/70 mt-1">
                  We'll let you know when you hit {@current_tenant.loyalty_threshold}.
                </p>
                <p :if={loyalty_earned?(@current_tenant, @current_customer)} class="text-sm text-base-content/70 mt-1">
                  Apply it on your next booking.
                </p>
              </div>
              <div class="text-2xl font-bold text-primary tabular-nums">
                {@current_customer.loyalty_count}/{@current_tenant.loyalty_threshold}
              </div>
            </div>
          </div>
        </section>

        <div
          :if={is_nil(@current_customer.email_verified_at)}
          class="alert alert-warning shadow-sm"
          role="alert"
        >
          <span class="hero-exclamation-triangle w-5 h-5 shrink-0" aria-hidden="true"></span>
          <div class="flex-1 text-sm">
            <span class="font-semibold">Verify your email</span>
            — check your inbox for the link we sent when you signed up.
          </div>
          <form action="/auth/customer/resend-verification" method="post" class="m-0">
            <input
              type="hidden"
              name="_csrf_token"
              value={Phoenix.Controller.get_csrf_token()}
            />
            <button class="btn btn-sm" type="submit">Resend</button>
          </form>
        </div>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">Account</h2>
              <button
                :if={@profile_mode == :read}
                phx-click="edit_profile"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-pencil w-4 h-4" aria-hidden="true"></span> Edit
              </button>
            </div>

            <dl
              :if={@profile_mode == :read}
              class="grid grid-cols-3 gap-x-3 gap-y-2 text-sm mt-2"
            >
              <dt class="text-base-content/60">Name</dt>
              <dd class="col-span-2 font-medium">{@current_customer.name}</dd>

              <dt class="text-base-content/60">Email</dt>
              <dd class="col-span-2">{to_string(@current_customer.email)}</dd>

              <dt class="text-base-content/60">Phone</dt>
              <dd class="col-span-2">
                {@current_customer.phone || "—"}
              </dd>
            </dl>

            <form
              :if={@profile_mode == :edit}
              id="profile-edit-form"
              phx-submit="save_profile"
              class="space-y-3 mt-3"
            >
              <div>
                <label class="label" for="profile-name">
                  <span class="label-text">Name</span>
                </label>
                <input
                  id="profile-name"
                  type="text"
                  name="profile[name]"
                  value={@current_customer.name}
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div>
                <label class="label" for="profile-phone">
                  <span class="label-text">Phone</span>
                </label>
                <input
                  id="profile-phone"
                  type="tel"
                  name="profile[phone]"
                  value={@current_customer.phone}
                  class="input input-bordered w-full"
                  placeholder="+1 555-555-1234"
                />
              </div>
              <div :if={@errors[:profile]} role="alert" class="alert alert-error text-sm">
                {@errors[:profile]}
              </div>
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_edit_profile" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Save</button>
              </div>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">Saved vehicles</h2>
              <button
                :if={not @vehicle_form?}
                phx-click="add_vehicle"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Add
              </button>
            </div>

            <div :if={@vehicles == []} class="text-sm text-base-content/60 mt-2">
              No saved vehicles yet — add one below or when you book.
            </div>

            <ul :if={@vehicles != []} class="divide-y divide-base-200 mt-2">
              <li
                :for={v <- @vehicles}
                class="py-3 flex items-center justify-between gap-3"
              >
                <div class="flex items-center gap-3 min-w-0">
                  <span
                    class="hero-truck w-5 h-5 text-base-content/40 shrink-0"
                    aria-hidden="true"
                  ></span>
                  <span class="font-medium truncate">{Vehicle.display_label(v)}</span>
                </div>
                <button
                  phx-click="delete_vehicle"
                  phx-value-id={v.id}
                  data-confirm="Delete this vehicle?"
                  class="btn btn-ghost btn-xs text-error"
                  aria-label="Delete"
                >
                  <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span>
                </button>
              </li>
            </ul>

            <form
              :if={@vehicle_form?}
              id="vehicle-add-form"
              phx-submit="save_vehicle"
              class="space-y-3 mt-3 border-t border-base-200 pt-4"
            >
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="label" for="v-year"><span class="label-text">Year</span></label>
                  <input
                    id="v-year"
                    type="number"
                    name="vehicle[year]"
                    class="input input-bordered w-full"
                    min="1900"
                    max="2100"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="v-color"><span class="label-text">Color</span></label>
                  <input
                    id="v-color"
                    type="text"
                    name="vehicle[color]"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="v-make"><span class="label-text">Make</span></label>
                  <input
                    id="v-make"
                    type="text"
                    name="vehicle[make]"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="v-model"><span class="label-text">Model</span></label>
                  <input
                    id="v-model"
                    type="text"
                    name="vehicle[model]"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
              </div>
              <div :if={@errors[:vehicle]} role="alert" class="alert alert-error text-sm">
                {@errors[:vehicle]}
              </div>
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_add_vehicle" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Save vehicle</button>
              </div>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <div class="flex items-center justify-between gap-2">
              <h2 class="card-title text-base">Saved addresses</h2>
              <button
                :if={not @address_form?}
                phx-click="add_address"
                class="btn btn-ghost btn-sm gap-1"
              >
                <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Add
              </button>
            </div>

            <div :if={@addresses == []} class="text-sm text-base-content/60 mt-2">
              No saved addresses yet — add one below or when you book.
            </div>

            <ul :if={@addresses != []} class="divide-y divide-base-200 mt-2">
              <li
                :for={a <- @addresses}
                class="py-3 flex items-center justify-between gap-3"
              >
                <div class="flex items-center gap-3 min-w-0">
                  <span
                    class="hero-map-pin w-5 h-5 text-base-content/40 shrink-0"
                    aria-hidden="true"
                  ></span>
                  <span class="font-medium truncate">{Address.display_label(a)}</span>
                </div>
                <button
                  phx-click="delete_address"
                  phx-value-id={a.id}
                  data-confirm="Delete this address?"
                  class="btn btn-ghost btn-xs text-error"
                  aria-label="Delete"
                >
                  <span class="hero-x-mark w-4 h-4" aria-hidden="true"></span>
                </button>
              </li>
            </ul>

            <form
              :if={@address_form?}
              id="address-add-form"
              phx-submit="save_address"
              class="space-y-3 mt-3 border-t border-base-200 pt-4"
            >
              <div>
                <label class="label" for="a-street1"><span class="label-text">Street</span></label>
                <input
                  id="a-street1"
                  type="text"
                  name="address[street_line1]"
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div class="grid grid-cols-3 gap-3">
                <div>
                  <label class="label" for="a-city"><span class="label-text">City</span></label>
                  <input
                    id="a-city"
                    type="text"
                    name="address[city]"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="a-state"><span class="label-text">State</span></label>
                  <input
                    id="a-state"
                    type="text"
                    name="address[state]"
                    class="input input-bordered w-full"
                    maxlength="2"
                    required
                  />
                </div>
                <div>
                  <label class="label" for="a-zip"><span class="label-text">ZIP</span></label>
                  <input
                    id="a-zip"
                    type="text"
                    name="address[zip]"
                    class="input input-bordered w-full"
                    required
                  />
                </div>
              </div>
              <div :if={@errors[:address]} role="alert" class="alert alert-error text-sm">
                {@errors[:address]}
              </div>
              <div class="flex justify-end gap-2">
                <button type="button" phx-click="cancel_add_address" class="btn btn-ghost">
                  Cancel
                </button>
                <button type="submit" class="btn btn-primary">Save address</button>
              </div>
            </form>
          </div>
        </section>

        <section
          :if={@subscriptions != []}
          class="card bg-base-100 shadow-sm border border-base-300"
        >
          <div class="card-body p-6">
            <h2 class="card-title text-base">Recurring bookings</h2>

            <ul class="divide-y divide-base-200 mt-2">
              <li :for={sub <- @subscriptions} class="py-3">
                <div class="flex items-start justify-between gap-3 flex-wrap">
                  <div class="min-w-0">
                    <div class="font-medium flex items-center gap-2">
                      <span>{(@service_map[sub.service_type_id] || %{name: "Service"}).name}</span>
                      <span class={"badge badge-sm " <> sub_badge(sub.status)}>
                        {sub.status}
                      </span>
                    </div>
                    <div class="text-sm text-base-content/70 mt-1">
                      Every {frequency_label(sub.frequency)} · next {fmt_when(sub.next_run_at)}
                    </div>
                    <div class="text-xs text-base-content/60 mt-1 truncate">
                      {sub.vehicle_description} · {sub.service_address}
                    </div>
                  </div>

                  <div class="flex gap-2">
                    <button
                      :if={sub.status == :active}
                      phx-click="pause_subscription"
                      phx-value-id={sub.id}
                      class="btn btn-ghost btn-xs gap-1"
                    >
                      <span class="hero-pause w-3 h-3" aria-hidden="true"></span> Pause
                    </button>
                    <button
                      :if={sub.status == :paused}
                      phx-click="resume_subscription"
                      phx-value-id={sub.id}
                      class="btn btn-success btn-xs gap-1"
                    >
                      <span class="hero-play w-3 h-3" aria-hidden="true"></span> Resume
                    </button>
                    <button
                      :if={sub.status != :cancelled}
                      phx-click="cancel_subscription"
                      phx-value-id={sub.id}
                      data-confirm="Cancel this recurring booking?"
                      class="btn btn-ghost btn-xs text-error gap-1"
                    >
                      <span class="hero-x-mark w-3 h-3" aria-hidden="true"></span> Cancel
                    </button>
                  </div>
                </div>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end

  defp sub_badge(:active), do: "badge-success"
  defp sub_badge(:paused), do: "badge-warning"
  defp sub_badge(:cancelled), do: "badge-ghost"

  # Loyalty card is visible whenever the tenant has configured a
  # threshold (nil = feature off). The card shows progress for
  # everyone who's tenant-onboarded loyalty, including brand-new
  # customers at 0 — the "earn a free wash" prompt is itself a
  # conversion lever.
  defp loyalty_visible?(%{loyalty_threshold: t}, %{loyalty_count: _}) when is_integer(t), do: true
  defp loyalty_visible?(_, _), do: false

  defp loyalty_earned?(%{loyalty_threshold: t}, %{loyalty_count: c})
       when is_integer(t) and is_integer(c),
       do: c >= t

  defp loyalty_earned?(_, _), do: false

  defp frequency_label(:weekly), do: "week"
  defp frequency_label(:biweekly), do: "2 weeks"
  defp frequency_label(:monthly), do: "month"

  defp fmt_when(%DateTime{} = dt), do: Calendar.strftime(dt, "%a %b %-d")
end
