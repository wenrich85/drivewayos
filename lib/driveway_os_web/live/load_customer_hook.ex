defmodule DrivewayOSWeb.LoadCustomerHook do
  @moduledoc """
  LiveView `on_mount` hook that mirrors the `LoadCustomer` plug into
  the LV socket.

  Reads `customer_token` from session, verifies it (including the
  AshAuth `tenant` claim against `current_tenant.id`), and assigns
  `current_customer` to the socket. When the token is missing,
  invalid, or scoped to a different tenant, `current_customer` is
  set to `nil` — LVs that REQUIRE auth handle redirection themselves
  (typical pattern: redirect to `/sign-in?return_to=/some/path`).

  Must run AFTER `LoadTenantHook` in the on_mount chain so
  `current_tenant` is already in scope.
  """
  import Phoenix.Component, only: [assign: 3]

  alias DrivewayOS.Accounts.Customer

  def on_mount(:default, _params, session, socket) do
    socket = assign(socket, :impersonated_by, Map.get(session, "impersonated_by"))

    socket =
      with %{} = tenant <- socket.assigns[:current_tenant],
           token when is_binary(token) <- Map.get(session, "customer_token"),
           {:ok, %{"sub" => subject}, _claims} <-
             AshAuthentication.Jwt.verify(token, :driveway_os, tenant: tenant.id),
           {:ok, customer} <-
             AshAuthentication.subject_to_user(subject, Customer, tenant: tenant.id) do
        assign(socket, :current_customer, customer)
      else
        _ -> assign(socket, :current_customer, nil)
      end

    {:cont, socket}
  end
end
