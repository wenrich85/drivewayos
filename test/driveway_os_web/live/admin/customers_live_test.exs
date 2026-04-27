defmodule DrivewayOSWeb.Admin.CustomersLiveTest do
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "cu-#{System.unique_integer([:positive])}",
        display_name: "Customers Admin",
        admin_email: "cu-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, alice} =
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

    %{tenant: tenant, admin: admin, alice: alice}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  test "non-admin → /", %{conn: conn, tenant: tenant, alice: alice} do
    conn = sign_in(conn, alice)

    assert {:error, {:live_redirect, %{to: "/"}}} =
             conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/admin/customers")
  end

  test "admin sees the customer list with both rows", ctx do
    conn = sign_in(ctx.conn, ctx.admin)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/customers")

    assert html =~ "Customers"
    assert html =~ ctx.admin.name
    assert html =~ ctx.alice.name
  end

  test "cross-tenant: admin sees no other tenant's customers", ctx do
    {:ok, %{tenant: other_tenant}} =
      Platform.provision_tenant(%{
        slug: "cu-other-#{System.unique_integer([:positive])}",
        display_name: "Other",
        admin_email: "cuo-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Other",
        admin_password: "Password123!"
      })

    {:ok, _stranger} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "stranger-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Stranger Danger"
        },
        tenant: other_tenant.id
      )
      |> Ash.create(authorize?: false)

    conn = sign_in(ctx.conn, ctx.admin)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/customers")

    refute html =~ "Stranger Danger"
  end

  describe "loyalty badge" do
    test "renders 'Free wash' badge for customers at or above the threshold", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 3})
      |> Ash.update!(authorize?: false)

      {:ok, regular} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "loyal-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Loyal Larry"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      Enum.each(1..3, fn _ ->
        regular
        |> Ash.reload!(authorize?: false)
        |> Ash.Changeset.for_update(:increment_loyalty, %{})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/customers")

      assert html =~ "Free wash"
    end

    test "no badge when tenant has no loyalty_threshold set", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/admin/customers")

      refute html =~ "Free wash"
    end
  end
end
