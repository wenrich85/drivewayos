defmodule DrivewayOSWeb.Plugs.LoadCustomer do
  @moduledoc """
  Reads `session[:customer_token]` and resolves it to a Customer in
  the CURRENT tenant's data slice. Runs after `LoadTenant` in the
  `:browser` pipeline.

  Sets:

      conn.assigns[:current_customer] = %Customer{} | nil

  Behavior:

    * No token in session                  → `nil`
    * No tenant in scope (marketing/admin) → `nil` (no-op)
    * Token from tenant A on tenant B's
      subdomain                            → `nil` (the customer
                                              lookup runs scoped to
                                              tenant B and finds
                                              nothing)
    * Malformed / expired / forged token   → `nil` (gracefully)
    * Valid token, customer exists in
      this tenant                          → `%Customer{}`

  This plug NEVER halts the conn. Routes that REQUIRE auth use a
  separate plug (`RequireCustomer`) that 401s when assigns are nil.
  """
  import Plug.Conn

  alias DrivewayOS.Accounts.Customer

  def init(opts), do: opts

  def call(conn, _opts) do
    with %{} = tenant <- conn.assigns[:current_tenant],
         token when is_binary(token) <- get_session(conn, :customer_token),
         # Passing `tenant:` to verify makes Joken validate the JWT's
         # `"tenant"` claim against this id. AshAuthentication mints
         # the claim automatically for multi-tenant resources, so a
         # token from tenant A presented on tenant B's subdomain
         # fails right here — before we ever look up a row.
         {:ok, %{"sub" => subject}, _claims} <-
           AshAuthentication.Jwt.verify(token, :driveway_os, tenant: tenant.id),
         {:ok, customer} <-
           AshAuthentication.subject_to_user(subject, Customer, tenant: tenant.id) do
      assign(conn, :current_customer, customer)
    else
      _ -> assign(conn, :current_customer, nil)
    end
  end
end
