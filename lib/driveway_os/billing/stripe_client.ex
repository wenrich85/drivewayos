defmodule DrivewayOS.Billing.StripeClient do
  @moduledoc """
  Behaviour for our (small, opinionated) Stripe API surface. Real
  prod traffic hits `DrivewayOS.Billing.StripeClient.Live`; tests
  swap in a Mox-backed implementation via the
  `:driveway_os, :stripe_client` config key.

  Keeping the surface small makes both mocking trivial AND keeps
  the platform-level Stripe-Connect threading honest — every
  function takes the connect_account explicitly so it's impossible
  for tenant A's call to accidentally hit tenant B's account.
  """

  @doc """
  Exchange a Stripe OAuth `code` for a connected account id. Used
  by the Connect onboarding flow exactly once per tenant.

  Returns `{:ok, %{stripe_user_id: "acct_..."}}` or `{:error, reason}`.
  """
  @callback exchange_oauth_code(code :: String.t()) ::
              {:ok, %{stripe_user_id: String.t()}} | {:error, term()}

  @doc """
  Create a Stripe Checkout Session on behalf of `connect_account`.
  Used when a customer books and we need to charge them.

  Params should include `:line_items`, `:mode`, `:success_url`,
  `:cancel_url`, `:application_fee_amount`, `:metadata`.

  Returns `{:ok, %{id: "cs_...", url: "https://checkout..."}}`.
  """
  @callback create_checkout_session(connect_account :: String.t(), params :: map()) ::
              {:ok, %{id: String.t(), url: String.t()}} | {:error, term()}

  @doc """
  Verify a Stripe webhook signature. Returns the parsed event
  on success or `{:error, reason}` if the signature doesn't
  match the configured webhook secret.
  """
  @callback construct_event(
              payload :: String.t(),
              signature :: String.t(),
              secret :: String.t()
            ) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Refund a charge by PaymentIntent id. Uses the tenant's
  connect_account so the refund actually comes from their Stripe
  balance, not the platform's.

  Returns `{:ok, %{id: "re_...", status: "succeeded" | ...}}` on
  success.
  """
  @callback refund_payment_intent(
              connect_account :: String.t(),
              payment_intent_id :: String.t()
            ) ::
              {:ok, %{id: String.t(), status: String.t()}} | {:error, term()}

  # --- Dispatcher ---

  @doc """
  Returns the configured client implementation. Real impl in prod,
  mock in test. Defaults to `Live` so dev/prod just work without
  config.
  """
  def impl,
    do: Application.get_env(:driveway_os, :stripe_client, DrivewayOS.Billing.StripeClient.Live)

  def exchange_oauth_code(code), do: impl().exchange_oauth_code(code)

  def create_checkout_session(connect_account, params),
    do: impl().create_checkout_session(connect_account, params)

  def construct_event(payload, signature, secret),
    do: impl().construct_event(payload, signature, secret)

  def refund_payment_intent(connect_account, payment_intent_id),
    do: impl().refund_payment_intent(connect_account, payment_intent_id)
end
