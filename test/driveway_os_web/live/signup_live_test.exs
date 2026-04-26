defmodule DrivewayOSWeb.SignupLiveTest do
  @moduledoc """
  V1 Slice 4: tenant signup flow.

  Form lives only on the marketing host (`lvh.me/signup`). Submitting
  it provisions a tenant + first admin Customer atomically via
  `Platform.provision_tenant/1`. On success, redirects to the new
  tenant's subdomain.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  require Ash.Query

  describe "rendering" do
    test "shows the signup form on the marketing host", %{conn: conn} do
      {:ok, _lv, html} =
        conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      assert html =~ "Start your shop"
      assert html =~ ~s(name="signup[slug]")
      assert html =~ ~s(name="signup[display_name]")
      assert html =~ ~s(name="signup[admin_email]")
      assert html =~ ~s(name="signup[admin_password]")
    end

    test "redirects away from /signup on a tenant subdomain", %{conn: conn} do
      {:ok, tenant} = create_tenant!()

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/signup")
    end
  end

  describe "submit (success)" do
    test "creates tenant + admin, redirects to tenant subdomain root", %{conn: conn} do
      slug = "newshop-#{System.unique_integer([:positive])}"

      {:ok, lv, _} =
        conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      result =
        lv
        |> form("#signup-form", %{
          "signup" => %{
            "slug" => slug,
            "display_name" => "New Shop",
            "admin_email" => "owner-#{System.unique_integer([:positive])}@example.com",
            "admin_name" => "Owner",
            "admin_password" => "Password123!",
            "admin_phone" => "+15125550111"
          }
        })
        |> render_submit()

      # LV has redirected externally to the new tenant subdomain. The
      # `redirect(socket, external: ...)` form produces a normal
      # :redirect tuple with the URL stored as `:to`.
      assert {:error, {:redirect, %{to: external_url}}} = result
      assert external_url =~ "#{slug}.lvh.me"

      # New behavior: redirect lands at the auto-signin endpoint with
      # a token + ?return_to=/admin so the operator skips the
      # /sign-in form and goes straight to the dashboard.
      assert external_url =~ "/auth/customer/store-token"
      assert external_url =~ "token="
      assert external_url =~ "return_to=%2Fadmin"

      # Verify side effects.
      {:ok, tenant} = Platform.get_tenant_by_slug(slug)
      assert tenant.display_name == "New Shop"

      {:ok, customers} =
        Customer
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert length(customers) == 1
      assert hd(customers).role == :admin
    end
  end

  describe "submit (error)" do
    setup do
      {:ok, tenant} = create_tenant!()
      %{taken_slug: tenant.slug}
    end

    test "taken slug shows an error and does not redirect",
         %{conn: conn, taken_slug: slug} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{
            "slug" => to_string(slug),
            "display_name" => "Stealing Slug",
            "admin_email" => "stealer@example.com",
            "admin_name" => "Stealer",
            "admin_password" => "Password123!"
          }
        })
        |> render_submit()

      assert html =~ "already taken" or html =~ "unavailable" or html =~ "error"
    end

    test "reserved slug rejected", %{conn: conn} do
      {:ok, lv, _} =
        conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{
            "slug" => "admin",
            "display_name" => "Reserved Slug Test",
            "admin_email" => "reserved@example.com",
            "admin_name" => "Reserved",
            "admin_password" => "Password123!"
          }
        })
        |> render_submit()

      assert html =~ "reserved" or html =~ "unavailable"
    end
  end

  defp create_tenant! do
    Tenant
    |> Ash.Changeset.for_create(:create, %{
      slug: "existing-#{System.unique_integer([:positive])}",
      display_name: "Existing"
    })
    |> Ash.create(authorize?: false)
  end
end
