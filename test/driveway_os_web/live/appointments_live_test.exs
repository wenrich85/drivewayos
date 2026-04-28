defmodule DrivewayOSWeb.AppointmentsLiveTest do
  @moduledoc """
  V1 Slice 7: customer's "My Appointments" list at
  `{slug}.lvh.me/appointments`.

  Auth-gated; shows only the signed-in customer's appointments in
  the current tenant.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "appts-#{System.unique_integer([:positive])}",
        display_name: "Appointments Test"
      })
      |> Ash.create(authorize?: false)

    {:ok, service} =
      ServiceType
      |> Ash.Changeset.for_create(
        :create,
        %{
          slug: "basic",
          name: "Basic Wash",
          base_price_cents: 5_000,
          duration_minutes: 45
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

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

    {:ok, other_customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "bob@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Bob"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, service: service, customer: customer, other_customer: other_customer}
  end

  test "auth gate: unauthenticated → /sign-in", %{conn: conn, tenant: tenant} do
    assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
             conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/appointments")
  end

  test "renders the customer's own appointments", ctx do
    {:ok, mine} = book!(ctx.tenant, ctx.customer, ctx.service)

    conn = sign_in(ctx.conn, ctx.customer)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

    assert html =~ "Basic Wash"
    assert html =~ Calendar.strftime(mine.scheduled_at, "%B %-d")
  end

  test "does NOT show another customer's appointments", ctx do
    {:ok, _theirs} = book!(ctx.tenant, ctx.other_customer, ctx.service)

    conn = sign_in(ctx.conn, ctx.customer)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

    # Empty-state message because Alice has no appointments and can't
    # see Bob's.
    assert html =~ "No appointments" or html =~ "haven't booked"
  end

  test "empty state when customer has no appointments", ctx do
    conn = sign_in(ctx.conn, ctx.customer)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

    assert html =~ "No appointments" or html =~ "haven't booked"
  end

  describe "upcoming + past split" do
    test "completed appointments land under 'Past' with inline 'Book again'", ctx do
      {:ok, upcoming} = book!(ctx.tenant, ctx.customer, ctx.service)

      # A second booking that's been walked through the full
      # status state machine to :completed lands in the Past
      # section.
      {:ok, completed} = book_at!(ctx.tenant, ctx.customer, ctx.service, 2 * 86_400)

      completed
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:start_wash, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:complete, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

      assert html =~ "Upcoming"
      assert html =~ "Past"
      # Past row gets the inline rebook anchor with ?from=<id>.
      assert html =~ ~s(href="/book?from=#{completed.id}")
      assert html =~ "Book again"

      # The pending booking shouldn't have a rebook button.
      refute html =~ ~s(href="/book?from=#{upcoming.id}")
    end

    test "all-upcoming list hides the Past section", ctx do
      {:ok, _} = book!(ctx.tenant, ctx.customer, ctx.service)

      conn = sign_in(ctx.conn, ctx.customer)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

      assert html =~ "Upcoming"
      # No Past header when there's nothing terminal-state.
      refute html =~ ~s(<h2 class="text-xs font-semibold uppercase tracking-wide text-base-content/60 mb-2">\n            Past\n          </h2>)
    end

    test "guest customers don't see the inline 'Book again' button", ctx do
      {:ok, guest} =
        Customer
        |> Ash.Changeset.for_create(
          :register_guest,
          %{
            email: "guest-#{System.unique_integer([:positive])}@example.com",
            name: "Guest"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, completed} = book!(ctx.tenant, guest, ctx.service)

      completed
      |> Ash.Changeset.for_update(:confirm, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:start_wash, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
      |> Ash.Changeset.for_update(:complete, %{})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      conn = sign_in(ctx.conn, guest)

      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/appointments")

      # Guest accounts are ephemeral — no "Book again" rebook hop
      # because the rebook flow needs a real account.
      refute html =~ "Book again"
    end
  end

  defp book_at!(tenant, customer, service, seconds_from_now) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: service.id,
        scheduled_at:
          DateTime.utc_now()
          |> DateTime.add(seconds_from_now, :second)
          |> DateTime.truncate(:second),
        duration_minutes: service.duration_minutes,
        price_cents: service.base_price_cents,
        vehicle_description: "Past vehicle",
        service_address: "1 Past Lane"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp book!(tenant, customer, service) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer.id,
        service_type_id: service.id,
        scheduled_at:
          DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
        duration_minutes: service.duration_minutes,
        price_cents: service.base_price_cents,
        vehicle_description: "Test vehicle",
        service_address: "1 Test Lane"
      },
      tenant: tenant.id
    )
    |> Ash.create(authorize?: false)
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)

    conn
    |> Plug.Test.init_test_session(%{customer_token: token})
  end
end
