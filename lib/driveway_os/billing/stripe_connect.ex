defmodule DrivewayOS.Billing.StripeConnect do
  @moduledoc """
  Stripe Connect Standard onboarding for tenants.

  Each tenant completes Stripe's OAuth flow exactly once. The flow:

      1. Tenant admin clicks "Connect Stripe" in our admin UI
      2. We mint a Platform.OauthState (CSRF token) bound to the
         tenant + redirect them to connect.stripe.com/oauth/authorize
      3. Tenant authorizes us; Stripe redirects them back to our
         /onboarding/stripe/callback?code=…&state=…
      4. We verify_state/1 → consume token → exchange code with
         Stripe → store stripe_user_id on Tenant + flip status

  After this, every API call we make on the tenant's behalf passes
  `connect_account: tenant.stripe_account_id` so charges land in
  the tenant's account, not ours, and our `application_fee_amount`
  is the platform's cut.
  """

  alias DrivewayOS.Billing.StripeClient
  alias DrivewayOS.Platform.{OauthState, Tenant}

  require Ash.Query

  @oauth_authorize_url "https://connect.stripe.com/oauth/authorize"

  @doc """
  Build the Stripe OAuth URL for `tenant`. Mints + persists a
  CSRF-safe state token bound to this tenant, then encodes it in
  the URL.
  """
  @spec oauth_url_for(Tenant.t()) :: String.t()
  def oauth_url_for(%Tenant{id: tenant_id}) do
    {:ok, state} =
      OauthState
      |> Ash.Changeset.for_create(:issue, %{
        tenant_id: tenant_id,
        purpose: :stripe_connect
      })
      |> Ash.create(authorize?: false)

    params = %{
      response_type: "code",
      client_id: client_id(),
      scope: "read_write",
      state: state.token,
      redirect_uri: redirect_uri()
    }

    @oauth_authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Verify a state token returned by Stripe on the OAuth callback.
  Returns `{:ok, tenant_id}` on success and consumes the token
  (single-use). `{:error, :invalid_state}` if missing, expired, or
  already used.
  """
  @spec verify_state(String.t()) :: {:ok, binary()} | {:error, :invalid_state}
  def verify_state(token) when is_binary(token) do
    case OauthState
         |> Ash.Query.for_read(:by_token, %{token: token})
         |> Ash.read(authorize?: false) do
      {:ok, [%OauthState{purpose: :stripe_connect} = state]} ->
        # Consume — single use even on success.
        Ash.destroy!(state, authorize?: false)
        {:ok, state.tenant_id}

      _ ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Exchange an OAuth `code` for the tenant's Stripe Connect account
  id and persist it on the tenant. Flips the tenant's status to
  `:active` (onboarding done) and sets stripe_account_status to
  `:enabled`.
  """
  @spec complete_onboarding(Tenant.t(), String.t()) ::
          {:ok, Tenant.t()} | {:error, term()}
  def complete_onboarding(%Tenant{} = tenant, code) when is_binary(code) do
    case StripeClient.exchange_oauth_code(code) do
      {:ok, %{stripe_user_id: account_id}} ->
        tenant
        |> Ash.Changeset.for_update(:update, %{
          stripe_account_id: account_id,
          stripe_account_status: :enabled,
          status: :active
        })
        |> Ash.update(authorize?: false)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Helpers ---

  defp client_id do
    Application.fetch_env!(:driveway_os, :stripe_client_id)
  end

  @doc """
  Returns true when Stripe Connect credentials are configured.
  Callers (the dashboard CTA, the onboarding controller) use this
  to short-circuit cleanly instead of calling `oauth_url_for/1`
  and getting a cryptic config error.
  """
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:driveway_os, :stripe_client_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  defp redirect_uri do
    Application.get_env(:driveway_os, :stripe_oauth_redirect_uri) ||
      build_default_redirect_uri()
  end

  defp build_default_redirect_uri do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    # OAuth callback lands on the marketing host (no tenant
    # subdomain) — we resolve which tenant this code belongs to via
    # the state token.
    "#{scheme}://#{host}#{port_suffix}/onboarding/stripe/callback"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
