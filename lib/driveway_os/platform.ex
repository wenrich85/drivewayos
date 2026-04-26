defmodule DrivewayOS.Platform do
  @moduledoc """
  The Platform domain — resources that sit ABOVE the tenant boundary.

  Everything here is deliberately NOT tenant-scoped. These resources
  anchor the multi-tenancy model itself:

    * `Tenant` — the tenant record. Every tenant-scoped resource
      across the app eventually points here via `tenant_id`.
    * `PlatformUser` — DrivewayOS operators (us). Separate auth from
      `Accounts.Customer`, with its own token signing secret.
    * `PlatformToken` — JWT storage for platform users.
    * `TenantSubscription` — SaaS billing (our Stripe charging the
      tenant for using DrivewayOS). Distinct from any
      tenant-side `Subscription` (which is the tenant charging their
      customer for a wash plan).

  See `docs/V1_SCOPE.md` for what's in scope this iteration.
  """
  use Ash.Domain

  require Ash.Query

  alias DrivewayOS.Platform.{
    CustomDomain,
    OauthState,
    PlatformToken,
    PlatformUser,
    Tenant,
    TenantSubscription
  }

  resources do
    resource Tenant
    resource PlatformUser
    resource PlatformToken
    resource TenantSubscription
    resource CustomDomain
    resource OauthState
  end

  @doc """
  Look up an active tenant by slug. Returns `{:ok, tenant}` or
  `{:error, :not_found}`. Archived tenants are excluded so the
  `LoadTenant` plug returns 404 for them.
  """
  @spec get_tenant_by_slug(String.t() | Ash.CiString.t()) ::
          {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) when is_binary(slug) do
    case Tenant
         |> Ash.Query.for_read(:by_slug, %{slug: slug})
         |> Ash.read(authorize?: false) do
      {:ok, [tenant]} -> {:ok, tenant}
      _ -> {:error, :not_found}
    end
  end

  def get_tenant_by_slug(%Ash.CiString{} = slug), do: get_tenant_by_slug(to_string(slug))

  @doc """
  Raising version of `get_tenant_by_slug/1`.
  """
  @spec get_tenant_by_slug!(String.t()) :: Tenant.t()
  def get_tenant_by_slug!(slug) do
    case get_tenant_by_slug(slug) do
      {:ok, tenant} -> tenant
      _ -> raise "tenant not found: #{slug}"
    end
  end

  @doc """
  Look up a tenant by Stripe Connect account id. Used by the Stripe
  webhook controller to resolve `event.account` → tenant.
  """
  @spec get_tenant_by_stripe_account(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_stripe_account(stripe_account_id) when is_binary(stripe_account_id) do
    case Tenant
         |> Ash.Query.for_read(:by_stripe_account, %{stripe_account_id: stripe_account_id})
         |> Ash.read(authorize?: false) do
      {:ok, [tenant]} -> {:ok, tenant}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Add a custom hostname for `tenant`. Starts unverified; the tenant
  must point DNS at our load balancer + then call
  `verify_custom_domain/1`.
  """
  @spec add_custom_domain(Tenant.t(), String.t()) ::
          {:ok, CustomDomain.t()} | {:error, term}
  def add_custom_domain(%Tenant{id: tenant_id}, hostname) when is_binary(hostname) do
    CustomDomain
    |> Ash.Changeset.for_create(:create, %{
      hostname: hostname,
      tenant_id: tenant_id
    })
    |> Ash.create(authorize?: false)
  end

  @doc """
  Verify a custom domain by checking DNS. Either:

    * The hostname's CNAME points at the configured edge target, OR
    * `_drivewayos.<hostname>` has a TXT record matching the
      `verification_token`

  Returns `{:ok, domain}` and persists `verified_at` on success;
  `{:error, :dns_not_pointing_here}` otherwise (the row is left
  un-verified so a retry is just another click).
  """
  @spec verify_custom_domain(CustomDomain.t()) ::
          {:ok, CustomDomain.t()} | {:error, :dns_not_pointing_here | term()}
  def verify_custom_domain(%CustomDomain{} = domain) do
    if dns_points_here?(domain) do
      domain
      |> Ash.Changeset.for_update(:verify, %{})
      |> Ash.update(authorize?: false)
    else
      {:error, :dns_not_pointing_here}
    end
  end

  defp dns_points_here?(%CustomDomain{} = domain) do
    cname_match?(domain) or txt_match?(domain)
  end

  defp cname_match?(%CustomDomain{hostname: hostname}) do
    expected = expected_cname_target() |> String.downcase() |> String.trim_trailing(".")

    case DrivewayOS.Platform.DnsResolver.lookup_cname(hostname) do
      {:ok, records} ->
        Enum.any?(records, fn r ->
          r |> String.downcase() |> String.trim_trailing(".") |> Kernel.==(expected)
        end)

      _ ->
        false
    end
  end

  defp txt_match?(%CustomDomain{hostname: hostname, verification_token: token}) do
    case DrivewayOS.Platform.DnsResolver.lookup_txt("_drivewayos." <> hostname) do
      {:ok, records} -> Enum.member?(records, token)
      _ -> false
    end
  end

  defp expected_cname_target do
    Application.get_env(:driveway_os, :custom_domain_cname_target) ||
      "edge." <> Application.fetch_env!(:driveway_os, :platform_host)
  end

  @doc """
  Look up the active tenant that owns `hostname`. Returns
  `{:error, :not_found}` for unknown hosts, unverified hosts, or
  hosts owned by an archived/suspended tenant.
  """
  @spec get_tenant_by_custom_hostname(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_custom_hostname(hostname) when is_binary(hostname) do
    normalized = hostname |> String.trim() |> String.downcase()

    case CustomDomain
         |> Ash.Query.for_read(:verified_for_hostname, %{hostname: normalized})
         |> Ash.Query.load(:tenant)
         |> Ash.read(authorize?: false) do
      {:ok, [%CustomDomain{tenant: %Tenant{status: status} = tenant}]}
      when status in [:active, :pending_onboarding] ->
        {:ok, tenant}

      _ ->
        {:error, :not_found}
    end
  end

  @reserved_slugs ~w(
    admin www api app platform status auth signup login signin
    sign-in sign-up dashboard help docs blog billing pay payments
    webhooks public assets cdn mail mailer support root
  )

  @doc """
  Reserved slugs that signup must reject. Centralised here so the
  signup LV's live availability check + the provisioning transaction
  agree on what's blocked.
  """
  @spec reserved_slugs() :: [String.t()]
  def reserved_slugs, do: @reserved_slugs

  @doc """
  Atomically provision a new tenant + first admin Customer + default
  service catalog.

  Wraps the creates in a single `Repo.transaction/1` — if any step
  fails (bad password, malformed email, etc.), the tenant insert
  rolls back so we never have an orphan tenant row with no one to
  log into it and no services to book.

  Slug validation:
    * Format enforced by Tenant resource (kebab regex)
    * Reserved-word blacklist enforced here

  Returns `{:ok, %{tenant: ..., admin: ...}}` or `{:error, term}`.
  """
  @spec provision_tenant(map()) :: {:ok, %{tenant: Tenant.t(), admin: term}} | {:error, term}
  def provision_tenant(%{} = attrs) do
    slug = attrs[:slug] || attrs["slug"]

    cond do
      is_nil(slug) or slug == "" ->
        {:error, :missing_slug}

      slug in @reserved_slugs ->
        {:error, :reserved_slug}

      true ->
        DrivewayOS.Repo.transaction(fn ->
          with {:ok, tenant} <- create_tenant(attrs),
               {:ok, admin} <- create_admin(tenant, attrs),
               :ok <- DrivewayOS.Scheduling.seed_default_service_types(tenant.id) do
            %{tenant: tenant, admin: admin}
          else
            {:error, reason} -> DrivewayOS.Repo.rollback(reason)
          end
        end)
    end
  end

  defp create_tenant(attrs) do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: attrs[:slug] || attrs["slug"],
      display_name: attrs[:display_name] || attrs["display_name"]
    })
    |> Ash.create(authorize?: false)
  end

  defp create_admin(%Tenant{id: tenant_id}, attrs) do
    DrivewayOS.Accounts.Customer
    |> Ash.Changeset.for_create(
      :register_with_password,
      %{
        email: attrs[:admin_email] || attrs["admin_email"],
        password: attrs[:admin_password] || attrs["admin_password"],
        password_confirmation: attrs[:admin_password] || attrs["admin_password"],
        name: attrs[:admin_name] || attrs["admin_name"],
        phone: attrs[:admin_phone] || attrs["admin_phone"]
      },
      tenant: tenant_id
    )
    |> Ash.Changeset.force_change_attribute(:role, :admin)
    |> Ash.create(authorize?: false)
  end
end
