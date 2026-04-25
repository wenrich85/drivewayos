defmodule DrivewayOS.Secrets do
  @moduledoc """
  AshAuthentication secret-resolver. Strategies declare which secrets
  they need; AshAuth calls back here to fetch them at request time
  (so a missing OAuth credential disables the strategy gracefully —
  no boot-time crash).

  Each callback either:

    * returns `{:ok, value}` — strategy works
    * returns `:error` — strategy can't authenticate (the redirect
      action will fail at runtime; setup is incomplete but boot is
      still clean)

  This is a deliberate shape: each provider's env vars get added when
  the operator sets up that provider with real credentials. Until
  then, the strategy is "configured" but not "live."
  """
  use AshAuthentication.Secret

  alias DrivewayOS.Accounts.Customer

  # Customer JWT token signing
  def secret_for([:authentication, :tokens, :signing_secret], Customer, _opts, _ctx) do
    fetch(:token_signing_secret)
  end

  # --- Google OAuth2 ---
  def secret_for([:authentication, :strategies, :google, :client_id], Customer, _, _),
    do: env("GOOGLE_CLIENT_ID")

  def secret_for([:authentication, :strategies, :google, :client_secret], Customer, _, _),
    do: env("GOOGLE_CLIENT_SECRET")

  def secret_for([:authentication, :strategies, :google, :redirect_uri], Customer, _, _),
    do: provider_redirect_uri("google")

  # --- Facebook (generic OAuth2) ---
  def secret_for([:authentication, :strategies, :facebook, :client_id], Customer, _, _),
    do: env("FACEBOOK_CLIENT_ID")

  def secret_for([:authentication, :strategies, :facebook, :client_secret], Customer, _, _),
    do: env("FACEBOOK_CLIENT_SECRET")

  def secret_for([:authentication, :strategies, :facebook, :redirect_uri], Customer, _, _),
    do: provider_redirect_uri("facebook")

  # --- Apple (Sign in with Apple) ---
  # Apple uses a JWT-based client_secret minted from the team_id +
  # private_key_id + private_key, so the values declared here are the
  # raw inputs; AshAuthentication assembles the JWT internally.
  def secret_for([:authentication, :strategies, :apple, :client_id], Customer, _, _),
    do: env("APPLE_CLIENT_ID")

  def secret_for([:authentication, :strategies, :apple, :team_id], Customer, _, _),
    do: env("APPLE_TEAM_ID")

  def secret_for([:authentication, :strategies, :apple, :private_key_id], Customer, _, _),
    do: env("APPLE_PRIVATE_KEY_ID")

  def secret_for([:authentication, :strategies, :apple, :private_key_path], Customer, _, _),
    do: env("APPLE_PRIVATE_KEY_PATH")

  def secret_for([:authentication, :strategies, :apple, :redirect_uri], Customer, _, _),
    do: provider_redirect_uri("apple")

  # --- Helpers ---

  defp env(name) do
    case System.get_env(name) do
      nil -> :error
      "" -> :error
      val -> {:ok, val}
    end
  end

  defp fetch(key) do
    case Application.get_env(:driveway_os, key) do
      nil -> :error
      val -> {:ok, val}
    end
  end

  # OAuth callbacks come back to the tenant's subdomain — the
  # `LoadTenant` plug runs first on the callback request and pins
  # `current_tenant` before the AshAuth callback handler runs. The
  # provider's app must be configured with `*.{platform_host}` as an
  # allowed redirect (or, in dev, an explicit `acme.lvh.me` entry).
  defp provider_redirect_uri(provider) do
    case Application.fetch_env(:driveway_os, :oauth_redirect_base) do
      {:ok, base} -> {:ok, "#{base}/auth/#{provider}/callback"}
      _ -> :error
    end
  end
end
