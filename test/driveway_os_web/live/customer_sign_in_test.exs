defmodule DrivewayOSWeb.CustomerSignInTest do
  @moduledoc """
  V1 Slice 6b: customer sign-in flow.

  Tenant-scoped sign-in: the form lives at `{slug}.lvh.me/sign-in`
  and authenticates against the current tenant's customers only.
  Cross-tenant credentials never work — even if the email + password
  exist on tenant B, signing in via tenant A's subdomain is rejected.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant

  describe "sign-in form" do
    setup do
      {:ok, tenant} = create_tenant!()

      {:ok, customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "alice@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Alice"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      %{tenant: tenant, customer: customer}
    end

    test "renders the sign-in form on a tenant subdomain", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

      assert html =~ "Sign in"
      assert html =~ ~s(name="signin[email]")
      assert html =~ ~s(name="signin[password]")
    end

    test "valid credentials create a session", %{conn: conn, tenant: tenant} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

      result =
        lv
        |> form("#sign-in-form", %{
          "signin" => %{"email" => "alice@example.com", "password" => "Password123!"}
        })
        |> render_submit()

      # Successful sign-in does an external redirect to a controller
      # that stores the token in session, then back to /.
      assert {:error, {:redirect, %{to: "/auth/customer/store-token" <> _}}} = result
    end

    test "wrong password shows an error", %{conn: conn, tenant: tenant} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

      html =
        lv
        |> form("#sign-in-form", %{
          "signin" => %{"email" => "alice@example.com", "password" => "WrongPassword!"}
        })
        |> render_submit()

      assert html =~ "Invalid" or html =~ "incorrect" or html =~ "could not"
    end

    test "credentials valid on a DIFFERENT tenant fail here", %{conn: conn, tenant: tenant} do
      # Create a customer with the same email on a different tenant.
      {:ok, other_tenant} = create_tenant!()

      {:ok, _other} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "bob@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Bob on Other Tenant"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      # Bob exists on `other_tenant` but not `tenant`.
      {:ok, lv, _} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

      html =
        lv
        |> form("#sign-in-form", %{
          "signin" => %{"email" => "bob@example.com", "password" => "Password123!"}
        })
        |> render_submit()

      assert html =~ "Invalid" or html =~ "incorrect" or html =~ "could not"
    end
  end

  describe "marketing host" do
    test "redirects to the marketing landing (no tenant to sign into)", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "lvh.me") |> live(~p"/sign-in")
    end
  end

  defp create_tenant! do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "signin-#{System.unique_integer([:positive])}",
      display_name: "Sign-In Test"
    })
    |> Ash.create(authorize?: false)
  end
end
