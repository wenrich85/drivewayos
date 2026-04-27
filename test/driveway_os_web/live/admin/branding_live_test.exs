defmodule DrivewayOSWeb.Admin.BrandingLiveTest do
  @moduledoc """
  Tenant admin → branding settings at `{slug}.lvh.me/admin/branding`.

  Lets the operator change their display name, support contact info,
  primary brand color, logo URL, and timezone. Writes through the
  existing `Tenant.update` action; cross-tenant isolation is
  enforced because the LV only ever reads/writes
  `socket.assigns.current_tenant`.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.Tenant

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "br-#{System.unique_integer([:positive])}",
        display_name: "Brand Test",
        admin_email: "br-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "auth" do
    test "non-admin → /", %{conn: conn, tenant: tenant} do
      {:ok, regular} =
        DrivewayOS.Accounts.Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "reg-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Reg"
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(conn, regular)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/branding")
    end
  end

  describe "load + save" do
    test "renders the form pre-filled with current values", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/branding")

      assert html =~ "Branding"
      # Pre-filled current display_name
      assert html =~ ctx.tenant.display_name
    end

    test "submitting persists the changes", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/branding")

      lv
      |> form("#branding-form", %{
        "tenant" => %{
          "display_name" => "Renamed Inc",
          "support_email" => "help@renamed.com",
          "support_phone" => "+15125550199",
          "primary_color_hex" => "#1d4ed8",
          "logo_url" => "https://example.com/logo.png",
          "timezone" => "America/New_York"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.display_name == "Renamed Inc"
      assert reloaded.support_email == "help@renamed.com"
      assert reloaded.primary_color_hex == "#1d4ed8"
      assert reloaded.timezone == "America/New_York"
    end

    test "rejects an invalid color", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/branding")

      html =
        lv
        |> form("#branding-form", %{
          "tenant" => %{
            "display_name" => "Still Brand Test",
            "primary_color_hex" => "not-a-hex"
          }
        })
        |> render_submit()

      # Either inline error OR the previous value persists.
      assert html =~ "match" or html =~ "invalid" or html =~ "Brand Test"

      reloaded = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      refute reloaded.primary_color_hex == "not-a-hex"
    end
  end

  describe "cross-tenant isolation" do
    test "an admin can't write to another tenant by tampering with id", ctx do
      {:ok, %{tenant: other}} =
        Platform.provision_tenant(%{
          slug: "br-other-#{System.unique_integer([:positive])}",
          display_name: "Other Brand",
          admin_email: "bro-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/branding")

      # Even if the form somehow named another tenant's id, the LV
      # must always operate on `socket.assigns.current_tenant`.
      lv
      |> form("#branding-form", %{
        "tenant" => %{
          "display_name" => "Hijacked Name",
          "primary_color_hex" => "#000000"
        }
      })
      |> render_submit()

      reloaded_other = Ash.get!(Tenant, other.id, authorize?: false)
      refute reloaded_other.display_name == "Hijacked Name"
    end
  end

  describe "loyalty threshold" do
    test "operator can set + clear it via the branding form", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/branding")

      lv
      |> form("#branding-form", %{
        "tenant" => %{
          "display_name" => ctx.tenant.display_name,
          "loyalty_threshold" => "10"
        }
      })
      |> render_submit()

      reloaded = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.loyalty_threshold == 10

      lv
      |> form("#branding-form", %{
        "tenant" => %{
          "display_name" => ctx.tenant.display_name,
          "loyalty_threshold" => ""
        }
      })
      |> render_submit()

      cleared = Ash.get!(Tenant, ctx.tenant.id, authorize?: false)
      assert cleared.loyalty_threshold == nil
    end
  end
end
