defmodule DrivewayOS.Onboarding.Providers.StripeConnect do
  @moduledoc """
  Stripe Connect onboarding provider — the V1 payment integration.

  This module is a thin adapter around the existing
  `DrivewayOS.Billing.StripeConnect` module: the OAuth + state +
  account creation logic stays where it's already tested and
  working, and this layer just answers the questions the
  `Onboarding.Provider` behaviour asks ("what's your category?",
  "is the tenant set up?", etc.) so the wizard + Registry can
  treat it uniformly with future providers.
  """
  @behaviour DrivewayOS.Onboarding.Provider

  alias DrivewayOS.Billing.StripeConnect, as: Billing
  alias DrivewayOS.Platform.Tenant

  @impl true
  def id, do: :stripe_connect

  @impl true
  def category, do: :payment

  @impl true
  def display do
    %{
      title: "Take card payments",
      blurb:
        "Connect a Stripe account so customers can pay at booking time. " <>
          "We'll add a small platform fee per charge.",
      cta_label: "Connect Stripe",
      href: "/onboarding/stripe/start"
    }
  end

  @impl true
  def configured?, do: Billing.configured?()

  @impl true
  def setup_complete?(%Tenant{stripe_account_id: id}), do: not is_nil(id)

  @impl true
  def provision(_tenant, _params), do: {:error, :hosted_required}
end
