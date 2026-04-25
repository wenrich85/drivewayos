defmodule DrivewayOSWeb.Plugs.LoadCustomerTest do
  @moduledoc """
  V1 Slice 2D: tenant-scoped customer auth at the HTTP layer.

  This plug runs AFTER `LoadTenant` in the `:browser` pipeline. It
  reads `session[:customer_token]`, verifies the JWT, and resolves
  the subject to a Customer **scoped to the current tenant**.

  The headline invariant: a JWT minted on tenant A, stuffed into the
  session, then presented on tenant B's subdomain MUST NOT result in
  an authenticated session. The customer simply doesn't exist in
  tenant B's data slice; `subject_to_user` returns no row; the plug
  assigns `current_customer = nil`.
  """
  use DrivewayOS.DataCase, async: false

  import Plug.Test
  import Plug.Conn

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOSWeb.Plugs.LoadCustomer

  @opts LoadCustomer.init([])

  setup do
    {:ok, tenant_a} = create_tenant!("Tenant A")
    {:ok, tenant_b} = create_tenant!("Tenant B")
    %{tenant_a: tenant_a, tenant_b: tenant_b}
  end

  describe "no token in session" do
    test "current_customer is nil", %{tenant_a: tenant} do
      conn =
        conn(:get, "/")
        |> init_test_session(%{})
        |> assign(:current_tenant, tenant)
        |> LoadCustomer.call(@opts)

      refute conn.halted
      assert conn.assigns[:current_customer] == nil
    end
  end

  describe "marketing / platform_admin context (no current_tenant)" do
    test "plug no-ops; current_customer not set", %{tenant_a: tenant} do
      # Even if a token is in session, with no tenant in scope the
      # plug doesn't try to resolve it — that's a different auth flow
      # (PlatformUser) we'll add in a later slice.
      token = mint_token!(tenant)

      conn =
        conn(:get, "/")
        |> init_test_session(%{customer_token: token})
        |> assign(:current_tenant, nil)
        |> LoadCustomer.call(@opts)

      assert conn.assigns[:current_customer] == nil
    end
  end

  describe "valid token + correct tenant" do
    test "loads the customer and sets current_customer", %{tenant_a: tenant} do
      {customer, token} = register_and_token!(tenant, "alice@example.com")

      conn =
        conn(:get, "/")
        |> init_test_session(%{customer_token: token})
        |> assign(:current_tenant, tenant)
        |> LoadCustomer.call(@opts)

      assert conn.assigns[:current_customer]
      assert conn.assigns[:current_customer].id == customer.id
    end
  end

  describe "stolen-JWT scenario (cross-tenant)" do
    test "token from tenant A presented on tenant B → current_customer is nil",
         %{tenant_a: a, tenant_b: b} do
      {_customer, token_from_a} = register_and_token!(a, "spy@example.com")

      # Same token, but the request hits tenant B's subdomain → current_tenant is B.
      conn =
        conn(:get, "/")
        |> init_test_session(%{customer_token: token_from_a})
        |> assign(:current_tenant, b)
        |> LoadCustomer.call(@opts)

      assert conn.assigns[:current_customer] == nil
    end
  end

  describe "malformed / invalid token" do
    test "plug fails gracefully — current_customer is nil", %{tenant_a: tenant} do
      conn =
        conn(:get, "/")
        |> init_test_session(%{customer_token: "not-a-real-jwt"})
        |> assign(:current_tenant, tenant)
        |> LoadCustomer.call(@opts)

      refute conn.halted
      assert conn.assigns[:current_customer] == nil
    end
  end

  # --- Helpers ---

  defp register_and_token!(tenant, email) do
    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: email,
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Test #{email}"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {customer, mint_token_for!(customer)}
  end

  defp mint_token_for!(customer) do
    {:ok, token, _claims} =
      AshAuthentication.Jwt.token_for_user(customer)

    token
  end

  # Mints a token without a backing customer — useful for the
  # "marketing context" test where we want a token-shaped string but
  # don't actually care if it resolves.
  defp mint_token!(tenant) do
    {_customer, token} =
      register_and_token!(tenant, "anon-#{System.unique_integer([:positive])}@example.com")

    token
  end

  defp create_tenant!(name) do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "load-cust-#{System.unique_integer([:positive])}",
      display_name: name
    })
    |> Ash.create(authorize?: false)
  end
end
