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
         |> load_blocks()}
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
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Availability</h1>
            <p class="text-base-content/70 text-sm">
              Define weekly time blocks. Customers pick from the resulting concrete slots when they book.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Add a block</h2>

            <div :if={@form_error} class="alert alert-error text-sm">{@form_error}</div>

            <form
              id="new-block-form"
              phx-submit="create_block"
              class="grid grid-cols-1 md:grid-cols-6 gap-2 mt-2"
            >
              <input
                type="text"
                name="block[name]"
                placeholder="Wednesday mornings"
                class="input input-bordered md:col-span-2"
                required
              />
              <select name="block[day_of_week]" class="select select-bordered" required>
                <option value="">Day</option>
                <option :for={{label, n} <- Enum.with_index(@days_of_week_labels)} value={n}>
                  {label}
                </option>
              </select>
              <input
                type="time"
                name="block[start_time]"
                class="input input-bordered"
                required
              />
              <input
                type="number"
                name="block[duration_minutes]"
                placeholder="Min"
                min="15"
                step="15"
                class="input input-bordered"
                required
              />
              <input
                type="number"
                name="block[capacity]"
                value="1"
                min="1"
                class="input input-bordered"
                required
              />
              <button type="submit" class="btn btn-primary md:col-span-6">Add block</button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Your blocks</h2>

            <div :if={@blocks == []} class="text-center py-6 text-base-content/60">
              No availability defined yet. Customers will see a free-form date picker until you add some.
            </div>

            <ul :if={@blocks != []} class="divide-y divide-base-200">
              <li :for={b <- @blocks} class="py-3 flex items-center justify-between gap-3 flex-wrap">
                <div>
                  <div class="font-semibold">
                    {b.name}
                  </div>
                  <div class="text-sm text-base-content/70">
                    {day_label(b.day_of_week)} at {time_label(b.start_time)} · {b.duration_minutes} min · capacity {b.capacity}
                  </div>
                </div>
                <button
                  phx-click="delete_block"
                  phx-value-id={b.id}
                  data-confirm={"Remove #{b.name}?"}
                  class="btn btn-ghost btn-sm text-error"
                >
                  Remove
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
