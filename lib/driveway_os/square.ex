defmodule DrivewayOS.Square do
  @moduledoc """
  Public namespace for Square integration. Aliases the OAuth, Client,
  and Charge submodules. The integration is split into:

    * `Square.OAuth` — connect/reconnect lifecycle (mirrors
      Accounting.OAuth from Phase 3).
    * `Square.Client` — HTTP behaviour (Mox-mockable in tests).
    * `Square.Charge` — Square Checkout (Payment Links) session
      creation, used at booking checkout time when the tenant has
      Square connected. (Lands in Task 8.)
  """

  alias DrivewayOS.Square.OAuth

  defdelegate oauth_url_for(tenant), to: OAuth
  defdelegate verify_state(token), to: OAuth
  defdelegate complete_onboarding(tenant, code), to: OAuth
  defdelegate configured?(), to: OAuth
end
