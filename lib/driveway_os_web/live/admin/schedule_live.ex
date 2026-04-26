defmodule DrivewayOSWeb.Admin.ScheduleLive do
  @moduledoc """
  Tenant admin → schedule template UI at `{slug}.lvh.me/admin/schedule`.

  Operator defines weekly availability blocks here; customers pick
  from the resulting concrete dated slots in the booking form.

  V1 keeps the editor simple — just a list + add/delete. No
  drag-and-drop calendar, no per-date overrides. V2 adds those.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Scheduling.BlockTemplate

  require Ash.Query

  @days_of_week ~w(Sunday Monday Tuesday Wednesday Thursday Friday Saturday)

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
         |> assign(:page_title, "Availability")
         |> assign(:days_of_week_labels, @days_of_week)
         |> assign(:form_error, nil)
         |> assign(:editing_id, nil)
         |> assign(:edit_error, nil)
         |> load_blocks()}
    end
  end

  def handle_event("edit_block", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:editing_id, id) |> assign(:edit_error, nil)}
  end

  def handle_event("cancel_edit", _, socket) do
    {:noreply, socket |> assign(:editing_id, nil) |> assign(:edit_error, nil)}
  end

  def handle_event("save_edit", %{"id" => id, "block" => params}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    attrs = %{
      name: params["name"],
      day_of_week: parse_int(params["day_of_week"]),
      start_time: parse_time(params["start_time"]),
      duration_minutes: parse_int(params["duration_minutes"]),
      capacity: parse_int(params["capacity"]) || 1
    }

    with {:ok, bt} <- Ash.get(BlockTemplate, id, tenant: tenant_id, authorize?: false),
         {:ok, _updated} <-
           bt
           |> Ash.Changeset.for_update(:update, attrs)
           |> Ash.update(authorize?: false, tenant: tenant_id) do
      {:noreply,
       socket
       |> assign(:editing_id, nil)
       |> assign(:edit_error, nil)
       |> load_blocks()}
    else
      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map(&Map.get(&1, :message, "is invalid")) |> Enum.join("; ")
        {:noreply, assign(socket, :edit_error, msg)}

      _ ->
        {:noreply, assign(socket, :edit_error, "Could not save.")}
    end
  end

  @impl true
  def handle_event("create_block", %{"block" => params}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    attrs = %{
      name: params["name"],
      day_of_week: parse_int(params["day_of_week"]),
      start_time: parse_time(params["start_time"]),
      duration_minutes: parse_int(params["duration_minutes"]),
      capacity: parse_int(params["capacity"]) || 1
    }

    case BlockTemplate
         |> Ash.Changeset.for_create(:create, attrs, tenant: tenant_id)
         |> Ash.create(authorize?: false) do
      {:ok, _bt} ->
        {:noreply,
         socket
         |> assign(:form_error, nil)
         |> load_blocks()}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg = errors |> Enum.map(&Map.get(&1, :message, "is invalid")) |> Enum.join("; ")
        {:noreply, assign(socket, :form_error, msg)}

      {:error, _} ->
        {:noreply, assign(socket, :form_error, "Could not save.")}
    end
  end

  def handle_event("delete_block", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case BlockTemplate
         |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
         |> Ash.Query.set_tenant(tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %BlockTemplate{} = bt} ->
        Ash.destroy!(bt, authorize?: false, tenant: tenant_id)
        {:noreply, load_blocks(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # --- Private ---

  defp load_blocks(socket) do
    tenant_id = socket.assigns.current_tenant.id

    blocks =
      BlockTemplate
      |> Ash.Query.set_tenant(tenant_id)
      |> Ash.Query.sort(day_of_week: :asc, start_time: :asc)
      |> Ash.read!(authorize?: false)

    assign(socket, :blocks, blocks)
  end

  defp parse_int(nil), do: nil

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> nil
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(s) when is_binary(s) do
    case Time.from_iso8601("#{s}:00") do
      {:ok, t} -> t
      _ -> nil
    end
  end

  defp day_label(n), do: Enum.at(@days_of_week, n, "Day #{n}")

  defp time_label(%Time{} = t), do: Calendar.strftime(t, "%-I:%M %p")

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Availability</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Define weekly time blocks. Customers pick from the resulting concrete slots when they book.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-4">
            <h2 class="card-title text-lg">Add a block</h2>

            <div :if={@form_error} role="alert" class="alert alert-error">
              <span class="hero-exclamation-circle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <span class="text-sm">{@form_error}</span>
            </div>

            <form
              id="new-block-form"
              phx-submit="create_block"
              class="grid grid-cols-1 md:grid-cols-6 gap-3"
            >
              <div class="md:col-span-2">
                <label class="label" for="blk-name">
                  <span class="label-text font-medium">Name</span>
                </label>
                <input
                  id="blk-name"
                  type="text"
                  name="block[name]"
                  placeholder="Wednesday mornings"
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div>
                <label class="label" for="blk-dow">
                  <span class="label-text font-medium">Day</span>
                </label>
                <select
                  id="blk-dow"
                  name="block[day_of_week]"
                  class="select select-bordered w-full"
                  required
                >
                  <option value="">—</option>
                  <option
                    :for={{label, n} <- Enum.with_index(@days_of_week_labels)}
                    value={n}
                  >
                    {label}
                  </option>
                </select>
              </div>
              <div>
                <label class="label" for="blk-start">
                  <span class="label-text font-medium">Start</span>
                </label>
                <input
                  id="blk-start"
                  type="time"
                  name="block[start_time]"
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div>
                <label class="label" for="blk-dur">
                  <span class="label-text font-medium">Duration</span>
                </label>
                <input
                  id="blk-dur"
                  type="number"
                  name="block[duration_minutes]"
                  placeholder="60"
                  min="15"
                  step="15"
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <div>
                <label class="label" for="blk-cap">
                  <span class="label-text font-medium">Capacity</span>
                </label>
                <input
                  id="blk-cap"
                  type="number"
                  name="block[capacity]"
                  value="1"
                  min="1"
                  class="input input-bordered w-full"
                  required
                />
              </div>
              <button type="submit" class="btn btn-primary md:col-span-6 gap-2">
                <span class="hero-plus w-5 h-5" aria-hidden="true"></span> Add block
              </button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-lg">Your blocks</h2>

            <div :if={@blocks == []} class="text-center py-8 px-4">
              <span
                class="hero-clock w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60 max-w-md mx-auto">
                No availability defined yet. Customers will see a free-form date picker until you add some.
              </p>
            </div>

            <ul :if={@blocks != []} class="divide-y divide-base-200">
              <li :for={b <- @blocks} class="py-4">
                <%= if @editing_id == b.id do %>
                  <div :if={@edit_error} role="alert" class="alert alert-error mb-3 text-sm">
                    {@edit_error}
                  </div>
                  <form
                    id={"edit-block-form-#{b.id}"}
                    phx-submit="save_edit"
                    phx-value-id={b.id}
                    class="grid grid-cols-1 md:grid-cols-6 gap-3"
                  >
                    <div class="md:col-span-2">
                      <label class="label" for={"edit-name-#{b.id}"}>
                        <span class="label-text font-medium">Name</span>
                      </label>
                      <input
                        id={"edit-name-#{b.id}"}
                        type="text"
                        name="block[name]"
                        value={b.name}
                        class="input input-bordered w-full"
                        required
                      />
                    </div>
                    <div>
                      <label class="label" for={"edit-dow-#{b.id}"}>
                        <span class="label-text font-medium">Day</span>
                      </label>
                      <select
                        id={"edit-dow-#{b.id}"}
                        name="block[day_of_week]"
                        class="select select-bordered w-full"
                        required
                      >
                        <option
                          :for={{label, n} <- Enum.with_index(@days_of_week_labels)}
                          value={n}
                          selected={b.day_of_week == n}
                        >
                          {label}
                        </option>
                      </select>
                    </div>
                    <div>
                      <label class="label" for={"edit-start-#{b.id}"}>
                        <span class="label-text font-medium">Start</span>
                      </label>
                      <input
                        id={"edit-start-#{b.id}"}
                        type="time"
                        name="block[start_time]"
                        value={Calendar.strftime(b.start_time, "%H:%M")}
                        class="input input-bordered w-full"
                        required
                      />
                    </div>
                    <div>
                      <label class="label" for={"edit-dur-#{b.id}"}>
                        <span class="label-text font-medium">Duration</span>
                      </label>
                      <input
                        id={"edit-dur-#{b.id}"}
                        type="number"
                        name="block[duration_minutes]"
                        value={b.duration_minutes}
                        min="15"
                        step="15"
                        class="input input-bordered w-full"
                        required
                      />
                    </div>
                    <div>
                      <label class="label" for={"edit-cap-#{b.id}"}>
                        <span class="label-text font-medium">Capacity</span>
                      </label>
                      <input
                        id={"edit-cap-#{b.id}"}
                        type="number"
                        name="block[capacity]"
                        value={b.capacity}
                        min="1"
                        class="input input-bordered w-full"
                        required
                      />
                    </div>
                    <div class="md:col-span-6 flex justify-end gap-2">
                      <button type="button" phx-click="cancel_edit" class="btn btn-ghost btn-sm">
                        Cancel
                      </button>
                      <button type="submit" class="btn btn-primary btn-sm">Save</button>
                    </div>
                  </form>
                <% else %>
                  <div class="flex items-center justify-between gap-3 flex-wrap">
                    <div>
                      <div class="font-semibold">{b.name}</div>
                      <div class="text-sm text-base-content/70 mt-0.5">
                        <span class="font-mono">{day_label(b.day_of_week)}</span>
                        at {time_label(b.start_time)} · {b.duration_minutes} min · capacity {b.capacity}
                      </div>
                    </div>
                    <div class="flex gap-2">
                      <button
                        phx-click="edit_block"
                        phx-value-id={b.id}
                        class="btn btn-ghost btn-sm gap-1"
                      >
                        <span class="hero-pencil w-4 h-4" aria-hidden="true"></span> Edit
                      </button>
                      <button
                        phx-click="delete_block"
                        phx-value-id={b.id}
                        data-confirm={"Remove #{b.name}?"}
                        class="btn btn-ghost btn-sm text-error gap-1"
                      >
                        <span class="hero-trash w-4 h-4" aria-hidden="true"></span> Remove
                      </button>
                    </div>
                  </div>
                <% end %>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </main>
    """
  end
end
