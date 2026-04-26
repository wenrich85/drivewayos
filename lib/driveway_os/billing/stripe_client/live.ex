defmodule DrivewayOS.Billing.StripeClient.Live do
  @moduledoc """
  Real Stripe API implementation of `DrivewayOS.Billing.StripeClient`.
  Used in dev + prod. Tests swap this for a Mox.

  All calls against tenant-specific resources MUST pass
  `connect_account:` so tenant isolation is enforced at the API
  boundary — never on the platform's own account.
  """
  @behaviour DrivewayOS.Billing.StripeClient

  @oauth_token_url "https://connect.stripe.com/oauth/token"

  @impl true
  def exchange_oauth_code(code) when is_binary(code) do
    secret_key = Application.fetch_env!(:driveway_os, :stripe_secret_key)

    body =
      URI.encode_query(%{
        client_secret: secret_key,
        code: code,
        grant_type: "authorization_code"
      })

    case Req.post(@oauth_token_url,
           body: body,
           headers: [{"content-type", "application/x-www-form-urlencoded"}]
         ) do
      {:ok, %{status: 200, body: %{"stripe_user_id" => acct_id}}} ->
        {:ok, %{stripe_user_id: acct_id}}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"stripe_user_id" => acct_id}} -> {:ok, %{stripe_user_id: acct_id}}
          _ -> {:error, :stripe_invalid_response}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:stripe_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_checkout_session(connect_account, params)
      when is_binary(connect_account) and is_map(params) do
    case Stripe.Checkout.Session.create(params, connect_account: connect_account) do
      {:ok, %{id: id, url: url}} -> {:ok, %{id: id, url: url}}
      {:error, %Stripe.Error{} = e} -> {:error, e}
      other -> {:error, other}
    end
  end

  @impl true
  def construct_event(payload, signature, secret)
      when is_binary(payload) and is_binary(signature) and is_binary(secret) do
    case Stripe.Webhook.construct_event(payload, signature, secret) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def refund_payment_intent(connect_account, payment_intent_id)
      when is_binary(connect_account) and is_binary(payment_intent_id) do
    case Stripe.Refund.create(
           %{payment_intent: payment_intent_id},
           connect_account: connect_account
         ) do
      {:ok, %{id: id, status: status}} -> {:ok, %{id: id, status: status}}
      {:error, %Stripe.Error{} = e} -> {:error, e}
      other -> {:error, other}
    end
  end
end
