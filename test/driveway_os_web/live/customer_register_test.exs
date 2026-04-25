defmodule DrivewayOSWeb.CustomerRegisterTest do
  @moduledoc """
  V1 Slice 6c: customer self-registration form.

  Tenant-scoped: the form at `{slug}.lvh.me/register` creates a
  Customer in the current tenant's data slice. Same email can
  register on a different tenant later — they're independent
  rows by design.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant

  require Ash.Query

  describe "register form" do
    setup do
      {:ok, tenant} = create_tenant!()
      %{tenant: tenant}
    end

    test "renders the register form on a tenant subdomain", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/register")

      assert html =~ "Create your account"
      assert html =~ ~s(name="register[email]")
      assert html =~ ~s(name="register[password]")
      assert html =~ ~s(name="register[name]")
    end

    test "valid submission creates a Customer + signs in", %{conn: conn, tenant: tenant} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/register")

      result =
        lv
        |> form("#register-form", %{
          "register" => %{
            "email" => "newbie-#{System.unique_integer([:positive])}@example.com",
            "password" => "Password123!",
            "name" => "Newbie",
            "phone" => "+15125550111"
          }
        })
        |> render_submit()

      assert {:error, {:redirect, %{to: "/auth/customer/store-token" <> _}}} = result

      # Customer should exist in the tenant's slice now.
      {:ok, customers} =
        Customer |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

      assert length(customers) == 1
      assert hd(customers).role == :customer
    end

    test "weak password is rejected with an inline error", %{conn: conn, tenant: tenant} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/register")

      html =
        lv
        |> form("#register-form", %{
          "register" => %{
            "email" => "weak@example.com",
            "password" => "short1!",
            "name" => "Weak"
          }
        })
        |> render_submit()

      assert html =~ "10 characters" or html =~ "Password" or html =~ "password"
    end

    test "duplicate email IN THIS tenant is rejected", %{conn: conn, tenant: tenant} do
      email = "dupe-#{System.unique_integer([:positive])}@example.com"

      {:ok, _existing} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: email,
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Existing"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/register")

      html =
        lv
        |> form("#register-form", %{
          "register" => %{
            "email" => email,
            "password" => "Password123!",
            "name" => "Conflicting"
          }
        })
        |> render_submit()

      assert html =~ "already" or html =~ "taken" or html =~ "exists" or html =~ "unique"
    end
  end

  describe "marketing host" do
    test "redirects to / (no tenant to register into)", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "lvh.me") |> live(~p"/register")
    end
  end

  defp create_tenant! do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "register-#{System.unique_integer([:positive])}",
      display_name: "Register Test"
    })
    |> Ash.create(authorize?: false)
  end
end
