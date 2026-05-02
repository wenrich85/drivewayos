defmodule DrivewayOS.Onboarding.Providers.ZohoBooks do
  @moduledoc """
  Onboarding adapter for Zoho Books. Hosted-redirect OAuth provider —
  `provision/2` returns `{:error, :hosted_required}`; the wizard
  routes the operator to `display.href` (= `/onboarding/zoho/start`)
  instead.

  Mirrors `Onboarding.Providers.StripeConnect`'s shape exactly. The
  underlying OAuth + API + sync logic lives in `DrivewayOS.Accounting`;
  this module just answers the questions the `Onboarding.Provider`
  behaviour asks.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Accounting.OAuth
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{AccountingConnection, Tenant}

  @impl true
  def id, do: :zoho_books

  @impl true
  def category, do: :accounting

  @impl true
  def display do
    %{
      title: "Sync to Zoho Books",
      blurb:
        "Auto-create invoices in Zoho Books when customers pay. " <>
          "Tax-time exports without manual entry.",
      cta_label: "Connect Zoho",
      href: "/onboarding/zoho/start"
    }
  end

  @impl true
  def configured?, do: OAuth.configured?()

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_accounting_connection(tid, :zoho_books) do
      {:ok, %AccountingConnection{access_token: at}} when is_binary(at) -> true
      _ -> false
    end
  end

  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}

  @impl true
  def affiliate_config do
    %{
      ref_param: "ref",
      ref_id: Application.get_env(:driveway_os, :zoho_affiliate_ref_id)
    }
  end

  @impl true
  def tenant_perk, do: nil
end
