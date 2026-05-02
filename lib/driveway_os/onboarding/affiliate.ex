defmodule DrivewayOS.Onboarding.Affiliate do
  @moduledoc """
  Phase 2 affiliate-tracking helpers.

  Three public functions:

    * `tag_url/2` — append the platform's affiliate ref to a URL
      using the provider's `affiliate_config/0`. Passthrough when
      no config is set.
    * `perk_copy/1` — visible perk copy for a provider, sourced
      from the provider's `tenant_perk/0` callback. Nil when none.
    * `log_event/4` — write an entry to `Platform.TenantReferral`.
      Errors are swallowed; revenue attribution is our metric, not
      the tenant's flow (see Phase 2 spec, decision #7).

  The provider modules themselves own the per-integration affiliate
  facts (via the `affiliate_config/0` and `tenant_perk/0` callbacks
  on `Onboarding.Provider`). This module just routes calls through
  the registry.

  Example metadata contracts (V1, freeform; documented here for
  greppability):

    * `:click` on Stripe → `%{wizard_step: :payment, oauth_state: "..."}`
    * `:provisioned` on Postmark → `%{server_id: "99001"}`
    * `:revenue_attributed` (Phase 4+) → `%{provider_payout_id: "...", cents: 1234}`
  """

  require Logger

  alias DrivewayOS.Onboarding.Registry
  alias DrivewayOS.Platform.{Tenant, TenantReferral}

  @spec tag_url(String.t(), atom()) :: String.t()
  def tag_url(url, provider_id) when is_binary(url) and is_atom(provider_id) do
    with {:ok, mod} <- Registry.fetch(provider_id),
         true <- function_exported?(mod, :affiliate_config, 0),
         %{ref_param: param, ref_id: id} when is_binary(id) and id != "" <-
           mod.affiliate_config() do
      append_query_param(url, param, id)
    else
      _ -> url
    end
  end

  @spec perk_copy(atom()) :: String.t() | nil
  def perk_copy(provider_id) when is_atom(provider_id) do
    with {:ok, mod} <- Registry.fetch(provider_id),
         true <- function_exported?(mod, :tenant_perk, 0) do
      mod.tenant_perk()
    else
      _ -> nil
    end
  end

  @spec log_event(Tenant.t(), atom(), atom(), map()) :: :ok
  def log_event(%Tenant{} = tenant, provider_id, event_type, metadata \\ %{})
      when is_atom(provider_id) and is_atom(event_type) and is_map(metadata) do
    TenantReferral
    |> Ash.Changeset.for_create(:log, %{
      tenant_id: tenant.id,
      provider: provider_id,
      event_type: event_type,
      metadata: metadata
    })
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Affiliate.log_event failed: tenant=#{tenant.id} " <>
            "provider=#{inspect(provider_id)} event=#{inspect(event_type)} " <>
            "reason=#{inspect(reason)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Affiliate.log_event raised: #{Exception.message(e)}")
      :ok
  end

  # --- Helpers ---

  defp append_query_param(url, param, value) do
    uri = URI.parse(url)

    new_query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.put(param, value)
      |> URI.encode_query()

    %{uri | query: new_query} |> URI.to_string()
  end
end
