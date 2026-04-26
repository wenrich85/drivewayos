defmodule DrivewayOS.Accounts do
  @moduledoc """
  The Accounts domain — tenant-scoped customer authentication +
  profile.

  Every resource in this domain has `multitenancy do strategy
  :attribute; attribute :tenant_id end`, so every Ash query in this
  domain must pass `tenant:` or it raises.

  V1 Slice 2A: password auth only. OAuth providers (Google, Apple,
  Facebook) land in Slice 2C as additional `strategies do … end`
  entries on `Customer`.
  """
  use Ash.Domain

  require Ash.Query

  resources do
    resource DrivewayOS.Accounts.Customer
    resource DrivewayOS.Accounts.Token
  end

  @doc """
  Returns every `:admin`-role Customer for the given tenant. Used
  by notification fan-outs (operator alert on new booking, etc.)
  Tenant-scoped — passing a tenant_id from a different tenant gets
  you that tenant's admins; cross-tenant leakage is impossible
  because the multitenancy filter applies.
  """
  @spec tenant_admins(binary()) :: [DrivewayOS.Accounts.Customer.t()]
  def tenant_admins(tenant_id) when is_binary(tenant_id) do
    case DrivewayOS.Accounts.Customer
         |> Ash.Query.filter(role == :admin)
         |> Ash.Query.set_tenant(tenant_id)
         |> Ash.read(authorize?: false) do
      {:ok, admins} -> admins
      _ -> []
    end
  end

  @doc """
  Returns the list of OAuth providers (`:google`, `:facebook`,
  `:apple`) that are fully configured at runtime — both the client
  credentials AND the redirect-base env var resolve to non-nil
  values.

  Used by `Auth.SignInLive` to render only the buttons that will
  actually work, instead of dead links to `/auth/customer/google`
  etc. when env vars aren't set.
  """
  @spec configured_oauth_providers() :: [atom()]
  def configured_oauth_providers do
    [:google, :facebook, :apple]
    |> Enum.filter(&provider_configured?/1)
  end

  defp provider_configured?(:google),
    do: env_set?("GOOGLE_CLIENT_ID") and env_set?("GOOGLE_CLIENT_SECRET") and oauth_base_set?()

  defp provider_configured?(:facebook),
    do:
      env_set?("FACEBOOK_CLIENT_ID") and env_set?("FACEBOOK_CLIENT_SECRET") and oauth_base_set?()

  defp provider_configured?(:apple),
    do:
      env_set?("APPLE_CLIENT_ID") and env_set?("APPLE_TEAM_ID") and
        env_set?("APPLE_PRIVATE_KEY_ID") and env_set?("APPLE_PRIVATE_KEY_PATH") and
        oauth_base_set?()

  defp env_set?(name) do
    case System.get_env(name) do
      nil -> false
      "" -> false
      _ -> true
    end
  end

  defp oauth_base_set? do
    case Application.fetch_env(:driveway_os, :oauth_redirect_base) do
      {:ok, base} when is_binary(base) and base != "" -> true
      _ -> false
    end
  end
end
