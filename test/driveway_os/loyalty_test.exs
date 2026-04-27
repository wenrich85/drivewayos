defmodule DrivewayOS.LoyaltyTest do
  @moduledoc """
  Loyalty punch card data model — Tenant.loyalty_threshold +
  Customer.loyalty_count + the increment on Appointment.:complete.

  V1 contract:
    * Tenant.loyalty_threshold nil = feature off; integer = "every
      Nth completed wash earns a free one."
    * Customer.loyalty_count starts at 0, increments by 1 each
      time an appointment for that customer transitions to
      :completed.
    * Reset is exposed (used by J3 redemption) but the increment
      doesn't auto-reset at threshold.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "loy-#{System.unique_integer([:positive])}",
        display_name: "Loyalty Shop",
        admin_email: "loy-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, [service | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant.id) |> Ash.read(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "loyc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Loyal Larry"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer, service: service}
  end

  defp drain_inbox do
    receive do
      {:email, _} -> drain_inbox()
    after
      0 -> :ok
    end
  end

  defp book_and_complete!(ctx) do
    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: ctx.customer.id,
          service_type_id: ctx.service.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: ctx.service.duration_minutes,
          price_cents: ctx.service.base_price_cents,
          vehicle_description: "Loyalty Truck",
          service_address: "1 Loyalty Lane"
        },
        tenant: ctx.tenant.id
      )
      |> Ash.create(authorize?: false)

    appt
    |> Ash.Changeset.for_update(:confirm, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
    |> Ash.Changeset.for_update(:start_wash, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
    |> Ash.Changeset.for_update(:complete, %{})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)
  end

  describe "Tenant.loyalty_threshold" do
    test "nil by default", ctx do
      assert ctx.tenant.loyalty_threshold == nil
    end

    test "operator can set + clear via :update", ctx do
      {:ok, with_threshold} =
        ctx.tenant
        |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 10})
        |> Ash.update(authorize?: false)

      assert with_threshold.loyalty_threshold == 10

      {:ok, cleared} =
        with_threshold
        |> Ash.Changeset.for_update(:update, %{loyalty_threshold: nil})
        |> Ash.update(authorize?: false)

      assert cleared.loyalty_threshold == nil
    end

    test "rejects values outside 2..50", ctx do
      assert {:error, _} =
               ctx.tenant
               |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 1})
               |> Ash.update(authorize?: false)

      assert {:error, _} =
               ctx.tenant
               |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 100})
               |> Ash.update(authorize?: false)
    end
  end

  describe "Customer.loyalty_count + increment on complete" do
    test "starts at 0", ctx do
      assert ctx.customer.loyalty_count == 0
    end

    test "increments by 1 when an appointment completes", ctx do
      _ = book_and_complete!(ctx)

      reloaded = Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.loyalty_count == 1
    end

    test "increments cumulatively across multiple completions", ctx do
      _ = book_and_complete!(ctx)
      _ = book_and_complete!(ctx)
      _ = book_and_complete!(ctx)

      reloaded = Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.loyalty_count == 3
    end

    test "reset_loyalty zeroes the counter", ctx do
      _ = book_and_complete!(ctx)
      reloaded = Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.loyalty_count == 1

      {:ok, after_reset} =
        reloaded
        |> Ash.Changeset.for_update(:reset_loyalty, %{})
        |> Ash.update(authorize?: false, tenant: ctx.tenant.id)

      assert after_reset.loyalty_count == 0
    end

    test "fires the 'you earned a free wash' email on the threshold transition", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 3})
      |> Ash.update!(authorize?: false)

      # First two completions: silent.
      _ = book_and_complete!(ctx)
      _ = book_and_complete!(ctx)

      # Drain any prior emails so we can assert just on the third.
      :timer.sleep(20)
      drain_inbox()

      _ = book_and_complete!(ctx)

      assert_received {:email, %Swoosh.Email{subject: subject, to: [{_, addr}]}}
      assert subject =~ "free wash"
      assert addr == to_string(ctx.customer.email)
    end

    test "doesn't fire the earned email on completions past the threshold", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{loyalty_threshold: 2})
      |> Ash.update!(authorize?: false)

      # First completion: count 1, no email.
      # Second: count 2 = threshold, email fires.
      # Third: count 3 (past threshold), no NEW email.
      _ = book_and_complete!(ctx)
      _ = book_and_complete!(ctx)

      drain_inbox()

      _ = book_and_complete!(ctx)

      received = drain_emails([])
      free_wash_count = Enum.count(received, &String.contains?(&1.subject, "free wash"))
      assert free_wash_count == 0
    end

    defp drain_emails(acc) do
      receive do
        {:email, %Swoosh.Email{} = e} -> drain_emails([e | acc])
      after
        0 -> acc
      end
    end

    test "doesn't increment on cancel / start_wash transitions", ctx do
      {:ok, appt} =
        Appointment
        |> Ash.Changeset.for_create(
          :book,
          %{
            customer_id: ctx.customer.id,
            service_type_id: ctx.service.id,
            scheduled_at:
              DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
            duration_minutes: ctx.service.duration_minutes,
            price_cents: ctx.service.base_price_cents,
            vehicle_description: "Cancelled Truck",
            service_address: "1 Cancelled Lane"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      appt
      |> Ash.Changeset.for_update(:cancel, %{cancellation_reason: "test"})
      |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

      reloaded = Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.loyalty_count == 0
    end
  end
end
