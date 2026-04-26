defmodule DrivewayOSWeb.Admin.CustomerDetailLiveTest do
  @moduledoc """
  Tenant admin → individual customer page at
  `/admin/customers/:id`. Shows the customer's contact info, every
  appointment they've ever had, and a free-text admin notes field
  the operator can edit.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "cd-#{System.unique_integer([:positive])}",
        display_name: "Customer Detail Shop",
        admin_email: "cd-#{System.unique_integer([:positive])}@example.com",
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
          name: "Alice Detail"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: alice.id,
          service_type_id: service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service.duration_minutes,
          price_cents: service.base_price_cents,
          vehicle_description: "Red Honda",
          service_address: "123 Cedar"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, alice: alice, appt: appt}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "auth" do
    test "non-admin can't view another customer's detail page", ctx do
      {:ok, other} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "other-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Other"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, other)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/customers/#{ctx.alice.id}")
    end
  end

  describe "view" do
    test "admin sees customer's name + appointment row", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      assert html =~ ctx.alice.name
      assert html =~ "Red Honda"
    end

    test "404s on a customer from another tenant", ctx do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "cdo-#{System.unique_integer([:positive])}",
          display_name: "Other Detail",
          admin_email: "cdo-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, other_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "stranger-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Stranger"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      # Admin on tenant A asking for tenant B's customer id → bounce.
      assert {:error, {:live_redirect, %{to: "/admin/customers"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/customers/#{other_customer.id}")
    end
  end

  describe "notes" do
    test "admin can save admin_notes", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      lv
      |> form("#notes-form", %{"customer" => %{"admin_notes" => "Gate code 4321; prefers Sat"}})
      |> render_submit()

      reloaded = Ash.get!(Customer, ctx.alice.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.admin_notes == "Gate code 4321; prefers Sat"
    end
  end
end
