defmodule DrivewayOS.Accounting.OAuth do
  @moduledoc """
  Zoho Books OAuth helper. Mirrors `DrivewayOS.Billing.StripeConnect`'s
  shape — same `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`,
  `configured?/0` quartet.

  V1 hardcodes the `.com` region (per spec decision #8).
  """

  alias DrivewayOS.Accounting.ZohoClient
  alias DrivewayOS.Platform.{AccountingConnection, OauthState, Tenant}

  require Ash.Query

  @oauth_authorize_url "https://accounts.zoho.com/oauth/v2/auth"

  @doc """
  Build the Zoho OAuth URL for `tenant`. Mints a CSRF-safe state
  token bound to the tenant, then encodes it in the URL.
  """
  @spec oauth_url_for(Tenant.t()) :: String.t()
  def oauth_url_for(%Tenant{id: tenant_id}) do
    {:ok, state} =
      OauthState
      |> Ash.Changeset.for_create(:issue, %{
        tenant_id: tenant_id,
        purpose: :zoho_books
      })
      |> Ash.create(authorize?: false)

    params = %{
      response_type: "code",
      client_id: client_id(),
      scope: "ZohoBooks.fullaccess.all",
      access_type: "offline",
      state: state.token,
      redirect_uri: redirect_uri()
    }

    @oauth_authorize_url <> "?" <> URI.encode_query(params)
  end

  @doc """
  Verify a state token and consume it (single-use).
  """
  @spec verify_state(String.t()) :: {:ok, binary()} | {:error, :invalid_state}
  def verify_state(token) when is_binary(token) do
    case OauthState
         |> Ash.Query.for_read(:by_token, %{token: token})
         |> Ash.read(authorize?: false) do
      {:ok, [%OauthState{purpose: :zoho_books} = state]} ->
        Ash.destroy!(state, authorize?: false)
        {:ok, state.tenant_id}

      _ ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Exchange a code for tokens, probe the tenant's first organization,
  and upsert an AccountingConnection. Reconnects (existing row) update
  the tokens; first connects create a new row.
  """
  @spec complete_onboarding(Tenant.t(), String.t()) ::
          {:ok, AccountingConnection.t()} | {:error, term()}
  def complete_onboarding(%Tenant{id: tenant_id}, code) when is_binary(code) do
    with {:ok, %{access_token: at, refresh_token: rt, expires_in: secs}} <-
           ZohoClient.impl().exchange_oauth_code(code, redirect_uri()),
         # Probe /organizations to discover the tenant's primary org_id.
         # We pass "" for org_id here because we don't have one yet — this
         # is the call that returns it. Subsequent provider calls all pass
         # the discovered org_id from the AccountingConnection row.
         {:ok, %{"organizations" => [%{"organization_id" => org_id} | _]}} <-
           ZohoClient.impl().api_get(at, "", "/organizations", []) do
      expires_at = DateTime.add(DateTime.utc_now(), secs, :second)
      upsert_connection(tenant_id, org_id, at, rt, expires_at)
    end
  end

  @doc "True when Zoho OAuth credentials are configured on the platform."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:driveway_os, :zoho_client_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  # --- Helpers ---

  defp upsert_connection(tenant_id, org_id, access_token, refresh_token, expires_at) do
    case DrivewayOS.Platform.get_accounting_connection(tenant_id, :zoho_books) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:refresh_tokens, %{
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at
        })
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, updated} ->
            updated
            |> Ash.Changeset.for_update(:resume, %{})
            |> Ash.update(authorize?: false)

          err ->
            err
        end

      {:error, :not_found} ->
        AccountingConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: tenant_id,
          provider: :zoho_books,
          external_org_id: org_id,
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at,
          region: "com"
        })
        |> Ash.create(authorize?: false)
    end
  end

  defp client_id, do: Application.fetch_env!(:driveway_os, :zoho_client_id)

  defp redirect_uri do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{host}#{port_suffix}/onboarding/zoho/callback"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
