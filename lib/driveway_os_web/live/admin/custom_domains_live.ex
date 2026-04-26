defmodule DrivewayOSWeb.Admin.CustomDomainsLive do
  @moduledoc """
  Tenant admin → custom domains UI at `{slug}.lvh.me/admin/domains`.

  Lets the operator wire up a hostname they own (e.g.
  `book.acmewash.com`) so it resolves to their DrivewayOS shop. The
  flow:

      1. Add hostname → row appears, status :pending
      2. Operator copies the CNAME target + verification TXT record
         into their DNS provider's UI
      3. Click "Verify" → we mark verified_at, routing now resolves
         the hostname to this tenant

  V1 ships routing only — SSL termination is the tenant's
  responsibility (Cloudflare in front, their own LB, etc.). Real
  DNS-based verification (poll for the CNAME pointing at us) is a
  V2 follow-up; for now "Verify" is an attestation: the operator is
  telling us they've set up DNS, and we trust them.

  Auth: same as the dashboard — must be a Customer with role
  `:admin` in the current tenant.
  """
  use DrivewayOSWeb, :live_view

  on_mount DrivewayOSWeb.LoadTenantHook
  on_mount DrivewayOSWeb.LoadCustomerHook

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.CustomDomain

  require Ash.Query

  # Where tenants point their CNAME. In dev/test this is the
  # platform host; in prod it's the load balancer's apex.
  defp cname_target do
    Application.get_env(:driveway_os, :custom_domain_cname_target) ||
      "edge.#{Application.fetch_env!(:driveway_os, :platform_host)}"
  end

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
         |> assign(:page_title, "Custom domains")
         |> assign(:cname_target, cname_target())
         |> assign(:form_error, nil)
         |> load_domains()}
    end
  end

  @impl true
  def handle_event("add_domain", %{"domain" => %{"hostname" => hostname}}, socket) do
    case Platform.add_custom_domain(socket.assigns.current_tenant, hostname) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:form_error, nil)
         |> load_domains()}

      {:error, %Ash.Error.Invalid{errors: errors}} ->
        msg =
          errors
          |> Enum.map(&Map.get(&1, :message, "is invalid"))
          |> Enum.join("; ")

        {:noreply, assign(socket, :form_error, msg)}

      {:error, _} ->
        {:noreply, assign(socket, :form_error, "Could not add domain.")}
    end
  end

  def handle_event("verify_domain", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    # Authorization: the domain must belong to the current tenant.
    # Otherwise an admin on tenant A could verify tenant B's domains
    # by guessing IDs.
    case CustomDomain
         |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %CustomDomain{} = cd} ->
        case Platform.verify_custom_domain(cd) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:form_error, nil)
             |> load_domains()}

          {:error, :dns_not_pointing_here} ->
            {:noreply,
             assign(
               socket,
               :form_error,
               "DNS isn't pointing here yet. CNAME or TXT record not found — give it a few minutes after adding records and try again."
             )}

          {:error, _other} ->
            {:noreply, assign(socket, :form_error, "Verification failed. Try again.")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("delete_domain", %{"id" => id}, socket) do
    tenant_id = socket.assigns.current_tenant.id

    case CustomDomain
         |> Ash.Query.filter(id == ^id and tenant_id == ^tenant_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %CustomDomain{} = cd} ->
        Ash.destroy!(cd, authorize?: false)
        {:noreply, load_domains(socket)}

      _ ->
        {:noreply, socket}
    end
  end

  # --- Private ---

  defp load_domains(socket) do
    tenant_id = socket.assigns.current_tenant.id

    domains =
      CustomDomain
      |> Ash.Query.filter(tenant_id == ^tenant_id)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.read!(authorize?: false)

    assign(socket, :domains, domains)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen bg-base-200 px-4 py-8">
      <div class="max-w-3xl mx-auto space-y-6">
        <div class="flex justify-between items-center flex-wrap gap-2">
          <div>
            <h1 class="text-3xl font-bold">Custom domains</h1>
            <p class="text-base-content/70 text-sm">
              Run your shop on a domain you own — like <code class="text-xs">book.{@current_tenant.display_name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")}.com</code>.
            </p>
          </div>
          <a href="/admin" class="btn btn-ghost btn-sm">← Dashboard</a>
        </div>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Add a domain</h2>
            <p class="text-sm text-base-content/70">
              You'll need access to your domain's DNS settings.
            </p>

            <div :if={@form_error} class="alert alert-error text-sm">{@form_error}</div>

            <form id="add-domain-form" phx-submit="add_domain" class="join w-full mt-2">
              <input
                type="text"
                name="domain[hostname]"
                placeholder="book.your-domain.com"
                class="input input-bordered join-item w-full"
                required
              />
              <button type="submit" class="btn btn-primary join-item">Add</button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow">
          <div class="card-body">
            <h2 class="card-title text-lg">Your domains</h2>

            <div :if={@domains == []} class="text-center py-6 text-base-content/60">
              No custom domains yet. Add one above to get started.
            </div>

            <ul :if={@domains != []} class="divide-y divide-base-200">
              <li :for={d <- @domains} class="py-4 space-y-2">
                <div class="flex items-center justify-between gap-2 flex-wrap">
                  <div class="flex items-center gap-2">
                    <code class="font-mono text-sm">{d.hostname}</code>
                    <span :if={d.verified_at} class="badge badge-success badge-sm">Verified</span>
                    <span :if={is_nil(d.verified_at)} class="badge badge-warning badge-sm">
                      Pending
                    </span>
                  </div>
                  <div class="flex gap-2">
                    <button
                      :if={is_nil(d.verified_at)}
                      phx-click="verify_domain"
                      phx-value-id={d.id}
                      class="btn btn-success btn-sm"
                    >
                      Verify
                    </button>
                    <button
                      phx-click="delete_domain"
                      phx-value-id={d.id}
                      data-confirm={"Remove #{d.hostname}?"}
                      class="btn btn-ghost btn-sm text-error"
                    >
                      Remove
                    </button>
                  </div>
                </div>

                <div :if={is_nil(d.verified_at)} class="bg-base-200 rounded p-3 text-sm space-y-2">
                  <p class="font-semibold">DNS records to add at your registrar:</p>
                  <div>
                    <span class="font-mono text-xs uppercase">CNAME</span>
                    <code class="font-mono ml-2">{d.hostname}</code>
                    <span class="mx-1">→</span>
                    <code class="font-mono">{@cname_target}</code>
                  </div>
                  <div>
                    <span class="font-mono text-xs uppercase">TXT</span>
                    <code class="font-mono ml-2">_drivewayos.{d.hostname}</code>
                    <span class="mx-1">=</span>
                    <code class="font-mono break-all">{d.verification_token}</code>
                  </div>
                  <p class="text-xs text-base-content/60 mt-2">
                    DNS can take a few minutes to a few hours to propagate. Click "Verify" once your records are live.
                  </p>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <p class="text-xs text-base-content/60 text-center">
          SSL termination is your responsibility for now — Cloudflare in front of {@cname_target} works great. We'll automate cert provisioning soon.
        </p>
      </div>
    </main>
    """
  end
end
