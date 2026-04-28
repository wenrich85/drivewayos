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
      # Walk-in booking entry point.
      assert html =~ ~s(href="/book?on_behalf_of=#{ctx.alice.id}")
      assert html =~ "Book a wash"
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

  describe "promote / demote" do
    test "Promote flips a customer's role to :admin", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      render_click(lv, "promote_to_admin")

      reloaded = Ash.get!(Customer, ctx.alice.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.role == :admin
    end

    test "Demote flips a non-self admin back to :customer", ctx do
      ctx.alice
      |> Ash.Changeset.for_update(:update, %{role: :admin})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      render_click(lv, "demote_to_customer")

      reloaded = Ash.get!(Customer, ctx.alice.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.role == :customer
    end

    test "can't demote yourself", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.admin.id}")

      html = render_click(lv, "demote_to_customer")

      assert html =~ "demote yourself"

      reloaded = Ash.get!(Customer, ctx.admin.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.role == :admin
    end

  end

  describe "loyalty visibility" do
    test "shows progress card when tenant has a threshold set", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 10})
      |> Ash.update!(authorize?: false)

      ctx.alice
      |> Ash.Changeset.for_update(:increment_loyalty, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:increment_loyalty, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      assert html =~ "Loyalty"
      assert html =~ "2/10"
    end

    test "shows 'free wash earned' state when count >= threshold", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 2})
      |> Ash.update!(authorize?: false)

      Enum.each(1..2, fn _ ->
        ctx.alice
        |> Ash.reload!(authorize?: false)
        |> Ash.Changeset.for_update(:increment_loyalty, %{})
        |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      assert html =~ "free wash earned"
    end

    test "card hidden when tenant has no threshold set", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      refute html =~ "Loyalty:"
      refute html =~ "free wash earned"
    end
  end

  describe "appointment history status filter" do
    test "filtering to 'completed' hides the pending appointment", ctx do
      # Add a second, completed appointment so we can prove filtering
      # actually scopes the list.
      {:ok, [service | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, completed_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.alice.id,
            service_type_id: service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(2 * 86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: service.duration_minutes,
            price_cents: service.base_price_cents,
            vehicle_description: "Blue Civic",
            service_address: "999 Pine"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      completed_appt
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:start_wash, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:complete, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      # Default: both rows visible.
      assert html =~ "Red Honda"
      assert html =~ "Blue Civic"

      # Filter to completed → pending row gone.
      filtered =
        lv
        |> element("#customer-history-filter-form")
        |> render_change(%{"status" => "completed"})

      refute filtered =~ "Red Honda"
      assert filtered =~ "Blue Civic"
    end
  end

  describe "subscriptions" do
    test "admin can create + manage a subscription for the customer", ctx do
      {:ok, [service | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/customers/#{ctx.alice.id}")

      html = render_click(lv, "show_subscribe_form")
      assert html =~ "admin-subscribe-form"

      future = DateTime.utc_now() |> DateTime.add(7 * 86_400, :second)

      lv
      |> form("#admin-subscribe-form", %{
        "sub" => %{
          "service_type_id" => service.id,
          "frequency" => "biweekly",
          "starts_at" => DateTime.to_iso8601(future) |> String.slice(0, 16),
          "vehicle_description" => "Admin-created vehicle",
          "service_address" => "1 Admin Created Lane"
        }
      })
      |> render_submit()

      {:ok, [sub]} =
        DrivewayOS.Scheduling.Subscription
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert sub.customer_id == ctx.alice.id
      assert sub.frequency == :biweekly
      assert sub.status == :active

      render_click(lv, "pause_subscription", %{"id" => sub.id})

      paused =
        Ash.get!(DrivewayOS.Scheduling.Subscription, sub.id,
          tenant: ctx.tenant.id,
          authorize?: false
        )

      assert paused.status == :paused
    end
  end
end
