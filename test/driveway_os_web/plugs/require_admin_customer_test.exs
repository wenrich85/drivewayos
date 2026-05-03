defmodule DrivewayOSWeb.Plugs.RequireAdminCustomerTest do
  @moduledoc """
  Shared auth guard for onboarding/OAuth controllers (Postmark, Resend,
  Stripe, Zoho, Square). Three checks, in order:

    1. No `current_tenant`        → redirect to `/`     (halt)
    2. No `current_customer`      → redirect to `/sign-in` (halt)
    3. Customer role is not :admin → redirect to `/`     (halt)
    4. Otherwise                  → pass through, not halted

  This consolidates two private duplicates and three inline `cond` blocks
  that diverged subtly over time — Postmark/Resend skipped the tenant nil
  check entirely.
  """
  use DrivewayOSWeb.ConnCase, async: true

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOSWeb.Plugs.RequireAdminCustomer

  @opts RequireAdminCustomer.init([])

  describe "no current_tenant" do
    test "redirects to / and halts", %{conn: conn} do
      conn =
        conn
        |> assign(:current_tenant, nil)
        |> assign(:current_customer, %Customer{role: :admin})
        |> RequireAdminCustomer.call(@opts)

      assert conn.halted
      assert redirected_to(conn) == "/"
    end

    test "redirects to / even when current_customer is also nil", %{conn: conn} do
      conn =
        conn
        |> assign(:current_tenant, nil)
        |> assign(:current_customer, nil)
        |> RequireAdminCustomer.call(@opts)

      assert conn.halted
      assert redirected_to(conn) == "/"
    end
  end

  describe "tenant present, no current_customer" do
    test "redirects to /sign-in and halts", %{conn: conn} do
      conn =
        conn
        |> assign(:current_tenant, %Tenant{id: Ecto.UUID.generate()})
        |> assign(:current_customer, nil)
        |> RequireAdminCustomer.call(@opts)

      assert conn.halted
      assert redirected_to(conn) == "/sign-in"
    end
  end

  describe "tenant + non-admin customer" do
    test "redirects to / and halts (role :customer)", %{conn: conn} do
      conn =
        conn
        |> assign(:current_tenant, %Tenant{id: Ecto.UUID.generate()})
        |> assign(:current_customer, %Customer{role: :customer})
        |> RequireAdminCustomer.call(@opts)

      assert conn.halted
      assert redirected_to(conn) == "/"
    end
  end

  describe "tenant + admin customer" do
    test "passes through, not halted, no redirect", %{conn: conn} do
      conn =
        conn
        |> assign(:current_tenant, %Tenant{id: Ecto.UUID.generate()})
        |> assign(:current_customer, %Customer{role: :admin})
        |> RequireAdminCustomer.call(@opts)

      refute conn.halted
      assert conn.status == nil
    end
  end
end
