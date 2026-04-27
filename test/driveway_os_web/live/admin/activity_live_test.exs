defmodule DrivewayOSWeb.Admin.ActivityLiveTest do
  @moduledoc """
  /admin/activity — read-only audit log viewer. Admin-gated;
  scoped to current_tenant via the AuditLog :recent_for_tenant
  read action.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "act-#{System.unique_integer([:positive])}",
        display_name: "Activity Test",
        admin_email: "act-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, regular} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "actc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Reg"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, regular: regular}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "auth gate" do
    test "non-admin → /", ctx do
      conn = sign_in(ctx.conn, ctx.regular)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/activity")
    end

    test "admin sees the page", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/activity")

      assert html =~ "Recent activity"
    end
  end

  describe "rendering entries" do
    test "shows audit entries scoped to this tenant", ctx do
      Platform.log_audit!(%{
        action: :appointment_refunded,
        tenant_id: ctx.tenant.id,
        target_type: "Appointment",
        target_id: "00000000-0000-0000-0000-000000000001",
        payload: %{"source" => "stripe_webhook"}
      })

      Platform.log_audit!(%{
        action: :tenant_branding_updated,
        tenant_id: ctx.tenant.id,
        target_type: "Tenant",
        target_id: ctx.tenant.id,
        payload: %{"changed_fields" => ["display_name"]}
      })

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/activity")

      assert html =~ "Refund"
      assert html =~ "Refund processed via Stripe webhook"
      assert html =~ "Branding updated"
      assert html =~ "Updated display_name"
    end

    test "doesn't leak entries from another tenant", ctx do
      {:ok, %{tenant: other}} =
        Platform.provision_tenant(%{
          slug: "actb-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "actbo-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      Platform.log_audit!(%{
        action: :appointment_refunded,
        tenant_id: other.id,
        target_type: "Appointment",
        target_id: "deadbeef-0000-0000-0000-000000000000",
        payload: %{"source" => "admin"}
      })

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/activity")

      refute html =~ "deadbeef"
    end
  end
end
