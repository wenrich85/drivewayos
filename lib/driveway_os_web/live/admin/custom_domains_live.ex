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
      {:ok, cd} ->
        Platform.log_audit!(%{
          action: :custom_domain_added,
          tenant_id: socket.assigns.current_tenant.id,
          target_type: "CustomDomain",
          target_id: cd.id,
          payload: %{"hostname" => cd.hostname}
        })

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
          {:ok, verified} ->
            Platform.log_audit!(%{
              action: :custom_domain_verified,
              tenant_id: tenant_id,
              target_type: "CustomDomain",
              target_id: verified.id,
              payload: %{"hostname" => verified.hostname}
            })

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

        Platform.log_audit!(%{
          action: :custom_domain_removed,
          tenant_id: tenant_id,
          target_type: "CustomDomain",
          target_id: cd.id,
          payload: %{"hostname" => cd.hostname}
        })

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
    <main class="min-h-screen bg-base-200 px-4 py-8 sm:py-12">
      <div class="max-w-3xl mx-auto space-y-6">
        <header>
          <a
            href="/admin"
            class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content transition-colors"
          >
            <span class="hero-arrow-left w-4 h-4" aria-hidden="true"></span> Dashboard
          </a>
          <h1 class="text-3xl font-bold tracking-tight mt-2">Custom domains</h1>
          <p class="text-sm text-base-content/70 mt-1">
            Run your shop on a domain you own — like
            <code class="text-xs font-mono">
              book.{@current_tenant.display_name |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")}.com
            </code>.
          </p>
        </header>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6 space-y-3">
            <div>
              <h2 class="card-title text-lg">Add a domain</h2>
              <p class="text-sm text-base-content/70">
                You'll need access to your domain's DNS settings.
              </p>
            </div>

            <div :if={@form_error} role="alert" class="alert alert-warning">
              <span class="hero-exclamation-triangle w-5 h-5 shrink-0" aria-hidden="true"></span>
              <span class="text-sm">{@form_error}</span>
            </div>

            <form id="add-domain-form" phx-submit="add_domain" class="join w-full">
              <input
                type="text"
                name="domain[hostname]"
                placeholder="book.your-domain.com"
                class="input input-bordered join-item w-full"
                required
              />
              <button type="submit" class="btn btn-primary join-item gap-1">
                <span class="hero-plus w-4 h-4" aria-hidden="true"></span> Add
              </button>
            </form>
          </div>
        </section>

        <section class="card bg-base-100 shadow-sm border border-base-300">
          <div class="card-body p-6">
            <h2 class="card-title text-lg">Your domains</h2>

            <div :if={@domains == []} class="text-center py-8 px-4">
              <span
                class="hero-globe-alt w-12 h-12 mx-auto text-base-content/30"
                aria-hidden="true"
              ></span>
              <p class="mt-2 text-sm text-base-content/60">No custom domains yet. Add one above to get started.</p>
            </div>

            <ul :if={@domains != []} class="divide-y divide-base-200">
              <li :for={d <- @domains} class="py-4 space-y-3">
                <div class="flex items-center justify-between gap-2 flex-wrap">
                  <div class="flex items-center gap-2 min-w-0">
                    <code class="font-mono text-sm truncate">{d.hostname}</code>
                    <span :if={d.verified_at} class="badge badge-success badge-sm gap-1">
                      <span class="hero-check w-3 h-3" aria-hidden="true"></span> Verified
                    </span>
                    <span :if={is_nil(d.verified_at)} class="badge badge-warning badge-sm">
                      Pending
                    </span>
                  </div>
                  <div class="flex gap-2">
                    <button
                      :if={is_nil(d.verified_at)}
                      phx-click="verify_domain"
                      phx-value-id={d.id}
                      class="btn btn-success btn-sm gap-1"
                    >
                      <span class="hero-shield-check w-4 h-4" aria-hidden="true"></span> Verify
                    </button>
                    <button
                      phx-click="delete_domain"
                      phx-value-id={d.id}
                      data-confirm={"Remove #{d.hostname}?"}
                      class="btn btn-ghost btn-sm text-error"
                      aria-label="Remove"
                    >
                      <span class="hero-trash w-4 h-4" aria-hidden="true"></span>
                    </button>
                  </div>
                </div>

                <div
                  :if={is_nil(d.verified_at)}
                  class="bg-base-200 rounded-lg p-4 text-sm space-y-3 border border-base-300"
                >
                  <p class="font-semibold">DNS records to add at your registrar:</p>
                  <div class="grid grid-cols-1 md:grid-cols-[auto_1fr] gap-x-3 gap-y-1 items-baseline">
                    <span class="badge badge-ghost badge-sm font-mono">CNAME</span>
                    <div class="font-mono text-xs break-all">
                      <code>{d.hostname}</code> → <code>{@cname_target}</code>
                    </div>

                    <span class="badge badge-ghost badge-sm font-mono">TXT</span>
                    <div class="font-mono text-xs break-all">
                      <code>_drivewayos.{d.hostname}</code> = <code>{d.verification_token}</code>
                    </div>
                  </div>
                  <p class="text-xs text-base-content/60">
                    DNS can take a few minutes to a few hours to propagate. Click "Verify" once your records are live.
                  </p>
                </div>
              </li>
            </ul>
          </div>
        </section>

        <p class="text-xs text-base-content/60 text-center">
          SSL termination is your responsibility for now — Cloudflare in front of
          <code class="font-mono">{@cname_target}</code> works great. We'll automate cert provisioning soon.
        </p>
      </div>
    </main>
    """
  end
end
