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
      assert external_url =~ "return_to=%2Fadmin%2Fonboarding"

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

  describe "live feedback" do
    test "auto-suggests a slug from the business name", %{conn: conn} do
      {:ok, lv, _} = conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{
            "display_name" => "Acme Mobile Wash",
            "slug" => "",
            "admin_email" => "",
            "admin_name" => "",
            "admin_password" => "",
            "admin_phone" => ""
          }
        })
        |> render_change(%{"_target" => ["signup", "display_name"]})

      # The slug input now carries the slugified business name and
      # the auto-fill hint is visible.
      assert html =~ ~s(value="acme-mobile-wash")
      assert html =~ "auto-filled"
      assert html =~ "is available"
    end

    test "stops auto-suggesting once the user edits the slug directly", %{conn: conn} do
      {:ok, lv, _} = conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      # First: fill display name, slug auto-fills.
      lv
      |> form("#signup-form", %{
        "signup" => %{"display_name" => "Acme Wash", "slug" => "", "admin_password" => ""}
      })
      |> render_change(%{"_target" => ["signup", "display_name"]})

      # Now: user types in the slug field directly, overriding.
      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{"display_name" => "Acme Wash", "slug" => "my-shop", "admin_password" => ""}
        })
        |> render_change(%{"_target" => ["signup", "slug"]})

      # Subsequent display_name typing must NOT clobber the manual slug.
      html2 =
        lv
        |> form("#signup-form", %{
          "signup" => %{
            "display_name" => "Different Name Now",
            "slug" => "my-shop",
            "admin_password" => ""
          }
        })
        |> render_change(%{"_target" => ["signup", "display_name"]})

      assert html =~ ~s(value="my-shop")
      assert html2 =~ ~s(value="my-shop")
      refute html2 =~ "auto-filled"
    end

    test "flags taken slug live", %{conn: conn} do
      {:ok, taken} = create_tenant!()

      {:ok, lv, _} = conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{"display_name" => "Taken", "slug" => to_string(taken.slug)}
        })
        |> render_change(%{"_target" => ["signup", "slug"]})

      assert html =~ "Another shop already has that URL"
    end

    test "submit button disabled until slug is :ok", %{conn: conn} do
      {:ok, _lv, html} = conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      # Initial render: slug empty → button disabled.
      assert html =~ ~s(disabled)
      assert html =~ "Create my shop"
    end

    test "password strength bullets light up as rules are satisfied", %{conn: conn} do
      {:ok, lv, _} = conn |> Map.put(:host, "lvh.me") |> live(~p"/signup")

      # Weak password: only lowercase satisfied.
      html =
        lv
        |> form("#signup-form", %{
          "signup" => %{"display_name" => "P", "admin_password" => "abc"}
        })
        |> render_change(%{"_target" => ["signup", "admin_password"]})

      assert html =~ "10+ characters"
      assert html =~ "One uppercase"
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
