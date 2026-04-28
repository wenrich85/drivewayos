defmodule DrivewayOSWeb.SubscriptionDetailLiveTest do
  @moduledoc """
  /subscriptions/:id — single-subscription view. Both the subscription's
  owning customer and a tenant admin can open it; everyone else gets
  bounced. Shows the subscription's metadata, the past appointments
  it's materialized so far, and pause/resume/cancel actions.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType, Subscription}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "sub-#{System.unique_integer([:positive])}",
        display_name: "Sub Detail Shop",
        admin_email: "sub-admin-#{System.unique_integer([:positive])}@example.com",
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

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    starts =
      DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.truncate(:second)

    {:ok, sub} =
      Subscription
      |> Ash.Changeset.for_create(
        :subscribe,
        %{
          customer_id: alice.id,
          service_type_id: service.id,
          frequency: :biweekly,
          starts_at: starts,
          vehicle_description: "Red Honda",
          service_address: "1 Cedar Ln"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, alice: alice, service: service, sub: sub}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    conn |> Plug.Test.init_test_session(%{customer_token: token})
  end

  describe "auth" do
    test "redirects unauthenticated visitors to /sign-in", ctx do
      assert {:error, {:live_redirect, %{to: to}}} =
               ctx.conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/subscriptions/#{ctx.sub.id}")

      assert to =~ "/sign-in"
    end

    test "non-owner non-admin gets bounced", ctx do
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
               |> live(~p"/subscriptions/#{ctx.sub.id}")
    end

    test "subscription from another tenant 404s", ctx do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "sub-other-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "sub-other-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      {:ok, [other_service | _]} =
        ServiceType |> Ash.Query.set_tenant(other_tenant.id) |> Ash.read(authorize?: false)

      {:ok, other_customer} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "z-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Z"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, other_sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: other_customer.id,
            service_type_id: other_service.id,
            frequency: :weekly,
            starts_at: DateTime.utc_now(),
            vehicle_description: "Zzz",
            service_address: "Z St"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.alice)

      # Tenant A's customer asking for tenant B's sub via tenant A's
      # subdomain → bounce.
      assert {:error, {:live_redirect, _}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/subscriptions/#{other_sub.id}")
    end
  end

  describe "view" do
    test "owner sees the subscription's metadata", ctx do
      conn = sign_in(ctx.conn, ctx.alice)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/subscriptions/#{ctx.sub.id}")

      assert html =~ ctx.service.name
      assert html =~ "biweekly"
      assert html =~ "Red Honda"
      assert html =~ "1 Cedar Ln"
      # Surfaces the per-run charge so the customer can decide
      # whether the recurring plan is still worth it.
      assert html =~ "per run"
    end

    test "admin can also open it", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/subscriptions/#{ctx.sub.id}")

      assert html =~ ctx.alice.name
      assert html =~ "Red Honda"
    end

    test "lists appointments matching this subscription since start", ctx do
      # Create an appointment for Alice + same service. Appointment.book
      # requires a future scheduled_at, so we go forward; the filter
      # uses `scheduled_at >= sub.starts_at` which the sub's 30-day-ago
      # start_at easily satisfies.
      {:ok, past_appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.alice.id,
            service_type_id: ctx.service.id,
            scheduled_at:
              DateTime.utc_now()
              |> DateTime.add(7 * 86_400, :second)
              |> DateTime.truncate(:second),
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Red Honda",
            service_address: "1 Cedar Ln"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      conn = sign_in(ctx.conn, ctx.alice)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/subscriptions/#{ctx.sub.id}")

      assert html =~ "Red Honda"
      # The appointment id-derived link should be present so customer
      # can drill in.
      assert html =~ "/appointments/#{past_appt.id}"
    end
  end

  describe "actions" do
    test "owner can pause + resume + cancel", ctx do
      conn = sign_in(ctx.conn, ctx.alice)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/subscriptions/#{ctx.sub.id}")

      render_click(lv, "pause")

      paused = Ash.get!(Subscription, ctx.sub.id, tenant: ctx.tenant.id, authorize?: false)
      assert paused.status == :paused

      render_click(lv, "resume")
      resumed = Ash.get!(Subscription, ctx.sub.id, tenant: ctx.tenant.id, authorize?: false)
      assert resumed.status == :active

      render_click(lv, "cancel")
      cancelled = Ash.get!(Subscription, ctx.sub.id, tenant: ctx.tenant.id, authorize?: false)
      assert cancelled.status == :cancelled
    end
  end
end
