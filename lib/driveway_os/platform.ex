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

  alias DrivewayOS.Platform.{PlatformToken, PlatformUser, Tenant, TenantSubscription}

  resources do
    resource Tenant
    resource PlatformUser
    resource PlatformToken
    resource TenantSubscription
  end

  @doc """
  Look up an active tenant by slug. Returns `{:ok, tenant}` or
  `{:error, :not_found}`. Archived tenants are excluded so the
  `LoadTenant` plug returns 404 for them.
  """
  @spec get_tenant_by_slug(String.t()) :: {:ok, Tenant.t()} | {:error, :not_found}
  def get_tenant_by_slug(slug) when is_binary(slug) do
    case Tenant
         |> Ash.Query.for_read(:by_slug, %{slug: slug})
         |> Ash.read(authorize?: false) do
      {:ok, [tenant]} -> {:ok, tenant}
      _ -> {:error, :not_found}
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
end
