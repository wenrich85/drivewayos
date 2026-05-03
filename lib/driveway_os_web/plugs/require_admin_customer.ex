defmodule DrivewayOSWeb.Plugs.RequireAdminCustomer do
  @moduledoc """
  Auth guard for admin-only onboarding/OAuth controllers.

  Runs after `LoadTenant` and `LoadCustomer` in the `:browser`
  pipeline. Three checks, in order:

    1. No `current_tenant`         → redirect `/`        + halt
    2. No `current_customer`       → redirect `/sign-in` + halt
    3. Customer role is not :admin → redirect `/`        + halt
    4. Otherwise                   → pass through

  Used by `PostmarkOnboardingController`, `ResendOnboardingController`,
  `StripeOnboardingController`, `ZohoOauthController`, and
  `SquareOauthController`.
  """
  use DrivewayOSWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      is_nil(conn.assigns[:current_tenant]) ->
        conn |> redirect(to: ~p"/") |> halt()

      is_nil(conn.assigns[:current_customer]) ->
        conn |> redirect(to: ~p"/sign-in") |> halt()

      conn.assigns.current_customer.role != :admin ->
        conn |> redirect(to: ~p"/") |> halt()

      true ->
        conn
    end
  end
end
