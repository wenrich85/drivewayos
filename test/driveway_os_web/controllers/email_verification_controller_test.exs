defmodule DrivewayOSWeb.EmailVerificationControllerTest do
  @moduledoc """
  /auth/customer/verify-email?token=...

  Customers click the link in a confirmation email; we verify the
  signed token, flip `email_verified_at`, and bounce them home.

  Tokens are tenant-scoped customer JWTs with an extra
  `purpose: "verify_email"` claim so they can't be presented as
  sign-in tokens.
  """
  use DrivewayOSWeb.ConnCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ev-#{System.unique_integer([:positive])}",
        display_name: "Email Verify Shop",
        admin_email: "ev-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "alice-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  describe "GET /auth/customer/verify-email" do
    test "valid token: flips email_verified_at + redirects to /",
         %{conn: conn, tenant: tenant, customer: customer} do
      assert is_nil(customer.email_verified_at)

      token = DrivewayOS.Notifications.EmailVerification.mint_token(customer)

      conn =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/auth/customer/verify-email?token=#{token}")

      assert redirected_to(conn) == "/"

      reloaded = Ash.get!(Customer, customer.id, tenant: tenant.id, authorize?: false)
      assert %DateTime{} = reloaded.email_verified_at
    end

    test "garbage token: 400", %{conn: conn, tenant: tenant} do
      conn =
        conn
        |> Map.put(:host, "#{tenant.slug}.lvh.me")
        |> get("/auth/customer/verify-email?token=not-a-real-token")

      assert conn.status == 400
    end

    test "token from another tenant: 400 (cross-tenant rejection)",
         %{conn: conn, customer: customer} do
      # Customer's tenant is in setup; we present the token on a
      # different tenant's host.
      {:ok, %{tenant: other}} =
        Platform.provision_tenant(%{
          slug: "evo-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "evo-#{System.unique_integer([:positive])}@example.com",
          admin_name: "X",
          admin_password: "Password123!"
        })

      token = DrivewayOS.Notifications.EmailVerification.mint_token(customer)

      conn =
        conn
        |> Map.put(:host, "#{other.slug}.lvh.me")
        |> get("/auth/customer/verify-email?token=#{token}")

      assert conn.status == 400
    end
  end
end
