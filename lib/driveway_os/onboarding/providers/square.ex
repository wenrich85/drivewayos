defmodule DrivewayOS.Onboarding.Providers.Square do
  @moduledoc """
  Onboarding adapter for Square. Hosted-redirect OAuth provider —
  `provision/2` returns `{:error, :hosted_required}`; the wizard
  routes the operator to `display.href` (= `/onboarding/square/start`).

  Mirrors `Onboarding.Providers.ZohoBooks`'s shape exactly. The
  underlying OAuth + Client + Charge logic lives in `DrivewayOS.Square`.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Square.OAuth
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.{PaymentConnection, Tenant}

  @impl true
  def id, do: :square

  @impl true
  def category, do: :payment

  @impl true
  def display do
    %{
      title: "Take card payments via Square",
      blurb:
        "Connect your existing Square account. Customers pay at booking; " <>
          "funds land in your Square balance.",
      cta_label: "Connect Square",
      href: "/onboarding/square/start"
    }
  end

  @impl true
  def configured?, do: OAuth.configured?()

  @impl true
  def setup_complete?(%Tenant{id: tid}) do
    case Platform.get_payment_connection(tid, :square) do
      {:ok, %PaymentConnection{access_token: at}} when is_binary(at) -> true
      _ -> false
    end
  end

  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}

  @impl true
  def affiliate_config do
    %{
      ref_param: "ref",
      ref_id: Application.get_env(:driveway_os, :square_affiliate_ref_id)
    }
  end

  @impl true
  def tenant_perk, do: nil
end
