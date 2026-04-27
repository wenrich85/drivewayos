defmodule DrivewayOS.Accounts.DeletionTest do
  @moduledoc """
  Anonymization orchestrator: scrubs identifying fields, cancels
  active subscriptions, destroys saved Vehicles + Addresses +
  BookingDrafts, and emails the customer a paper trail before
  the email itself goes synthetic.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.{Customer, Deletion}
  alias DrivewayOS.Fleet.{Address, Vehicle}
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{BookingDraft, ServiceType, Subscription}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "del-#{System.unique_integer([:positive])}",
        display_name: "Delete Test",
        admin_email: "del-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "delc-#{System.unique_integer([:positive])}@example.com",
          password: "GoodPassword123!",
          password_confirmation: "GoodPassword123!",
          name: "Will Vanish",
          phone: "+15125559999"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  describe "request/2" do
    test "scrubs identifying fields + stamps deleted_at", ctx do
      assert :ok = Deletion.request(ctx.tenant, ctx.customer)

      reloaded = Ash.get!(Customer, ctx.customer.id, tenant: ctx.tenant.id, authorize?: false)

      assert to_string(reloaded.email) == "deleted-#{ctx.customer.id}@deleted.invalid"
      assert reloaded.name == "Deleted customer"
      assert reloaded.phone == nil
      assert reloaded.hashed_password == nil
      assert reloaded.deleted_at != nil
    end

    test "destroys saved vehicles + addresses + booking drafts", ctx do
      {:ok, _v} =
        Vehicle
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            year: 2022,
            make: "Subaru",
            model: "Outback",
            color: "Blue"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _a} =
        Address
        |> Ash.Changeset.for_create(
          :add,
          %{
            customer_id: ctx.customer.id,
            street_line1: "1 Vanish Lane",
            city: "SA",
            state: "TX",
            zip: "78261"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _d} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{customer_id: ctx.customer.id, step: "service", data: %{}},
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      :ok = Deletion.request(ctx.tenant, ctx.customer)

      assert {:ok, []} =
               Vehicle
               |> Ash.Query.filter(customer_id == ^ctx.customer.id)
               |> Ash.Query.set_tenant(ctx.tenant.id)
               |> Ash.read(authorize?: false)

      assert {:ok, []} =
               Address
               |> Ash.Query.filter(customer_id == ^ctx.customer.id)
               |> Ash.Query.set_tenant(ctx.tenant.id)
               |> Ash.read(authorize?: false)

      assert {:ok, []} =
               BookingDraft
               |> Ash.Query.filter(customer_id == ^ctx.customer.id)
               |> Ash.Query.set_tenant(ctx.tenant.id)
               |> Ash.read(authorize?: false)
    end

    test "cancels active subscriptions", ctx do
      {:ok, [service | _]} =
        ServiceType |> Ash.Query.set_tenant(ctx.tenant.id) |> Ash.read(authorize?: false)

      {:ok, sub} =
        Subscription
        |> Ash.Changeset.for_create(
          :subscribe,
          %{
            customer_id: ctx.customer.id,
            service_type_id: service.id,
            frequency: :biweekly,
            starts_at: DateTime.utc_now() |> DateTime.add(86_400, :second),
            service_address: "1 Sub Lane",
            vehicle_description: "Sub Truck"
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      :ok = Deletion.request(ctx.tenant, ctx.customer)

      reloaded = Ash.get!(Subscription, sub.id, tenant: ctx.tenant.id, authorize?: false)
      assert reloaded.status == :cancelled
    end

    test "fires the account-deleted email BEFORE scrubbing", ctx do
      :ok = Deletion.request(ctx.tenant, ctx.customer)

      # Mailbox should have an email addressed to the original
      # email (NOT the synthetic one).
      assert_received {:email, %Swoosh.Email{subject: subject, to: [{_, addr}]}}
      assert subject =~ "deleted"
      assert addr == to_string(ctx.customer.email)
      refute addr =~ "deleted.invalid"
    end

    test "anonymized customer can no longer sign in with the old password", ctx do
      :ok = Deletion.request(ctx.tenant, ctx.customer)

      assert {:error, _} =
               Customer
               |> Ash.Query.for_read(
                 :sign_in_with_password,
                 %{
                   email: to_string(ctx.customer.email),
                   password: "GoodPassword123!"
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.read_one(authorize?: false)
    end
  end
end
