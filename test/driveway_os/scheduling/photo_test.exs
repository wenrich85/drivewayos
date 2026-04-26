defmodule DrivewayOS.Scheduling.PhotoTest do
  @moduledoc """
  Pre-booking photos. Customers attach 1-N images to a booking
  during the wizard so the operator can quote / route / pre-stage
  before arrival. Same data model serves :before / :after photos
  added by techs in the field, but the wizard only writes :pre_booking.

  V1 contract:
    * Tenant-scoped
    * Belongs to an Appointment (required) and Customer (required)
    * `kind` constrained to :pre_booking | :before | :after | :damage
    * Cross-tenant FK validation on both customer_id and appointment_id
    * `:for_appointment` read action lists photos for one appointment
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.{Appointment, Photo, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ph-#{System.unique_integer([:positive])}",
        display_name: "Photo Test Shop",
        admin_email: "ph-#{System.unique_integer([:positive])}@example.com",
        admin_name: "PhAdmin",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "phc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Ph Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, [service | _]} =
      ServiceType
      |> Ash.Query.set_tenant(tenant.id)
      |> Ash.read(authorize?: false)

    {:ok, appt} = make_appt(tenant.id, customer.id, service)

    %{tenant: tenant, customer: customer, appt: appt}
  end

  defp make_appt(tenant_id, customer_id, service) do
    Appointment
    |> Ash.Changeset.for_create(
      :book,
      %{
        customer_id: customer_id,
        service_type_id: service.id,
        scheduled_at: DateTime.utc_now() |> DateTime.add(2, :day),
        duration_minutes: service.duration_minutes,
        price_cents: service.base_price_cents,
        vehicle_description: "2022 Subaru Outback (Blue)",
        service_address: "123 Main St"
      },
      tenant: tenant_id
    )
    |> Ash.create(authorize?: false)
  end

  describe "create" do
    test "valid pre_booking photo", ctx do
      {:ok, p} =
        Photo
        |> Ash.Changeset.for_create(
          :attach,
          %{
            customer_id: ctx.customer.id,
            appointment_id: ctx.appt.id,
            kind: :pre_booking,
            storage_path: "tenants/#{ctx.tenant.id}/appts/#{ctx.appt.id}/abc.jpg",
            content_type: "image/jpeg",
            byte_size: 12_345
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert p.tenant_id == ctx.tenant.id
      assert p.customer_id == ctx.customer.id
      assert p.appointment_id == ctx.appt.id
      assert p.kind == :pre_booking
      assert p.byte_size == 12_345
    end

    test "rejects invalid kind", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Photo
               |> Ash.Changeset.for_create(
                 :attach,
                 %{
                   customer_id: ctx.customer.id,
                   appointment_id: ctx.appt.id,
                   kind: :bogus,
                   storage_path: "x.jpg",
                   content_type: "image/jpeg",
                   byte_size: 1
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "rejects content_type that isn't image/*", ctx do
      assert {:error, %Ash.Error.Invalid{}} =
               Photo
               |> Ash.Changeset.for_create(
                 :attach,
                 %{
                   customer_id: ctx.customer.id,
                   appointment_id: ctx.appt.id,
                   kind: :pre_booking,
                   storage_path: "x.exe",
                   content_type: "application/octet-stream",
                   byte_size: 1
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "cross-tenant FK validation: rejects an appointment from another tenant", ctx do
      {:ok, %{tenant: other_tenant}} =
        Platform.provision_tenant(%{
          slug: "pho-#{System.unique_integer([:positive])}",
          display_name: "Other",
          admin_email: "pho-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Other",
          admin_password: "Password123!"
        })

      {:ok, other_cust} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "phoc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "Other Cust"
          },
          tenant: other_tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [other_service | _]} =
        ServiceType
        |> Ash.Query.set_tenant(other_tenant.id)
        |> Ash.read(authorize?: false)

      {:ok, other_appt} = make_appt(other_tenant.id, other_cust.id, other_service)

      # tenant A trying to attach a photo to tenant B's appt must fail.
      assert {:error, _} =
               Photo
               |> Ash.Changeset.for_create(
                 :attach,
                 %{
                   customer_id: ctx.customer.id,
                   appointment_id: other_appt.id,
                   kind: :pre_booking,
                   storage_path: "x.jpg",
                   content_type: "image/jpeg",
                   byte_size: 1
                 },
                 tenant: ctx.tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe ":for_appointment read action" do
    test "lists photos for an appointment newest-first", ctx do
      Enum.each(1..3, fn i ->
        Photo
        |> Ash.Changeset.for_create(
          :attach,
          %{
            customer_id: ctx.customer.id,
            appointment_id: ctx.appt.id,
            kind: :pre_booking,
            storage_path: "p#{i}.jpg",
            content_type: "image/jpeg",
            byte_size: i * 100
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create!(authorize?: false)

        # Tiny pause so inserted_at differs.
        Process.sleep(2)
      end)

      {:ok, photos} =
        Photo
        |> Ash.Query.for_read(:for_appointment, %{appointment_id: ctx.appt.id})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert length(photos) == 3
      [newest | _] = photos
      assert newest.storage_path == "p3.jpg"
    end
  end

  describe "tenant isolation" do
    test "tenant A can't read tenant B's photos", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "phb-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "phb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_cust} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "phbc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [b_service | _]} =
        ServiceType
        |> Ash.Query.set_tenant(tenant_b.id)
        |> Ash.read(authorize?: false)

      {:ok, b_appt} = make_appt(tenant_b.id, b_cust.id, b_service)

      {:ok, _} =
        Photo
        |> Ash.Changeset.for_create(
          :attach,
          %{
            customer_id: b_cust.id,
            appointment_id: b_appt.id,
            kind: :pre_booking,
            storage_path: "b.jpg",
            content_type: "image/jpeg",
            byte_size: 1
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results_for_a} =
        Photo
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results_for_a == []
    end
  end
end
