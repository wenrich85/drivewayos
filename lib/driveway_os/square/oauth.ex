defmodule DrivewayOS.Square.OAuth do
  @moduledoc """
  Square OAuth helper. Mirrors `DrivewayOS.Accounting.OAuth`'s shape —
  same `oauth_url_for/1`, `verify_state/1`, `complete_onboarding/2`,
  `configured?/0` quartet.

  V1 hardcodes prod base URL via app env (sandbox toggle via
  SQUARE_OAUTH_BASE).
  """

  alias DrivewayOS.Square.Client
  alias DrivewayOS.Platform.{OauthState, PaymentConnection, Tenant}

  require Ash.Query

  @doc """
  Build the Square OAuth URL for `tenant`. Mints a CSRF-safe state
  token bound to the tenant.
  """
  @spec oauth_url_for(Tenant.t()) :: String.t()
  def oauth_url_for(%Tenant{id: tenant_id}) do
    {:ok, state} =
      OauthState
      |> Ash.Changeset.for_create(:issue, %{
        tenant_id: tenant_id,
        purpose: :square
      })
      |> Ash.create(authorize?: false)

    params = %{
      response_type: "code",
      client_id: client_id(),
      scope: "PAYMENTS_WRITE PAYMENTS_READ MERCHANT_PROFILE_READ",
      session: "false",
      state: state.token,
      redirect_uri: redirect_uri()
    }

    "#{oauth_base()}/oauth2/authorize?" <> URI.encode_query(params)
  end

  @doc """
  Verify a state token and consume it (single-use). Pins
  purpose: :square so a Stripe/Zoho-purpose token can't satisfy
  a Square callback.
  """
  @spec verify_state(String.t()) :: {:ok, binary()} | {:error, :invalid_state}
  def verify_state(token) when is_binary(token) do
    case OauthState
         |> Ash.Query.for_read(:by_token, %{token: token})
         |> Ash.read(authorize?: false) do
      {:ok, [%OauthState{purpose: :square} = state]} ->
        Ash.destroy!(state, authorize?: false)
        {:ok, state.tenant_id}

      _ ->
        {:error, :invalid_state}
    end
  end

  @doc """
  Exchange a code for tokens, upsert PaymentConnection. Reconnects
  (existing row) update tokens + clear disconnected_at via the
  :reconnect action; first connects create a new row.
  """
  @spec complete_onboarding(Tenant.t(), String.t()) ::
          {:ok, PaymentConnection.t()} | {:error, term()}
  def complete_onboarding(%Tenant{id: tenant_id}, code) when is_binary(code) do
    with {:ok, %{access_token: at, refresh_token: rt, expires_in: secs, merchant_id: mid}} <-
           Client.impl().exchange_oauth_code(code, redirect_uri()) do
      expires_at = DateTime.add(DateTime.utc_now(), secs, :second)
      upsert_connection(tenant_id, mid, at, rt, expires_at)
    end
  end

  @doc "True when Square OAuth credentials are configured on the platform."
  @spec configured?() :: boolean()
  def configured? do
    case Application.get_env(:driveway_os, :square_app_id) do
      id when is_binary(id) and id != "" -> true
      _ -> false
    end
  end

  # --- Helpers ---

  defp upsert_connection(tenant_id, merchant_id, access_token, refresh_token, expires_at) do
    case DrivewayOS.Platform.get_payment_connection(tenant_id, :square) do
      {:ok, conn} ->
        conn
        |> Ash.Changeset.for_update(:reconnect, %{
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at,
          external_merchant_id: merchant_id
        })
        |> Ash.update(authorize?: false)

      {:error, :not_found} ->
        PaymentConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: tenant_id,
          provider: :square,
          external_merchant_id: merchant_id,
          access_token: access_token,
          refresh_token: refresh_token,
          access_token_expires_at: expires_at
        })
        |> Ash.create(authorize?: false)
    end
  end

  defp client_id, do: Application.fetch_env!(:driveway_os, :square_app_id)

  defp oauth_base, do: Application.get_env(:driveway_os, :square_oauth_base, "https://connect.squareup.com")

  defp redirect_uri do
    host = Application.fetch_env!(:driveway_os, :platform_host)

    {scheme, port_suffix} =
      if host == "lvh.me" do
        port = endpoint_port() || 4000
        {"http", ":#{port}"}
      else
        {"https", ""}
      end

    "#{scheme}://#{host}#{port_suffix}/onboarding/square/callback"
  end

  defp endpoint_port do
    Application.get_env(:driveway_os, DrivewayOSWeb.Endpoint)
    |> Kernel.||([])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port)
  end
end
