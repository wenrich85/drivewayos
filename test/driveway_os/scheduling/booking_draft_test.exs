defmodule DrivewayOS.Scheduling.BookingDraftTest do
  @moduledoc """
  In-progress booking-wizard state, persisted server-side so a
  signed-in customer can close the tab and pick up where they left
  off. One draft per (tenant, customer) — upserts overwrite.

  V1 contract:
    * Tenant-scoped
    * Belongs to a Customer (required — guests don't get drafts in
      V1 because the session-identity problem is exactly what makes
      guest checkouts ephemeral)
    * `step` is a free-string atom-name (so we don't have to
      migrate when new steps land)
    * `data` is a map (jsonb)
    * `:upsert` overwrites on conflict per the unique_per_customer
      identity
    * `:for_customer` returns the single draft or nil
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.BookingDraft

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "bd-#{System.unique_integer([:positive])}",
        display_name: "Draft Test",
        admin_email: "bd-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Admin",
        admin_password: "Password123!"
      })

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "bdc-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "BD Customer"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  describe ":upsert" do
    test "first upsert creates a row", ctx do
      {:ok, draft} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            customer_id: ctx.customer.id,
            step: "vehicle",
            data: %{"service_type_id" => "abc"}
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      assert draft.tenant_id == ctx.tenant.id
      assert draft.customer_id == ctx.customer.id
      assert draft.step == "vehicle"
      assert draft.data == %{"service_type_id" => "abc"}
    end

    test "second upsert overwrites the first (one row per customer)", ctx do
      {:ok, _} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            customer_id: ctx.customer.id,
            step: "vehicle",
            data: %{"service_type_id" => "abc"}
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            customer_id: ctx.customer.id,
            step: "schedule",
            data: %{"service_type_id" => "abc", "vehicle_description" => "Truck"}
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, drafts} =
        BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert length(drafts) == 1
      [d] = drafts
      assert d.step == "schedule"
      assert d.data["vehicle_description"] == "Truck"
    end
  end

  describe ":for_customer" do
    test "returns the existing draft", ctx do
      {:ok, _} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            customer_id: ctx.customer.id,
            step: "address",
            data: %{}
          },
          tenant: ctx.tenant.id
        )
        |> Ash.create(authorize?: false)

      {:ok, [d]} =
        BookingDraft
        |> Ash.Query.for_read(:for_customer, %{customer_id: ctx.customer.id})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert d.step == "address"
    end

    test "returns [] when no draft exists", ctx do
      {:ok, results} =
        BookingDraft
        |> Ash.Query.for_read(:for_customer, %{customer_id: ctx.customer.id})
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end

  describe "tenant isolation" do
    test "tenant A can't see tenant B's drafts", ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "bdo-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "bdo-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, b_cust} =
        Customer
        |> Ash.Changeset.for_create(
          :register_with_password,
          %{
            email: "bdoc-#{System.unique_integer([:positive])}@example.com",
            password: "Password123!",
            password_confirmation: "Password123!",
            name: "B Cust"
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, _} =
        BookingDraft
        |> Ash.Changeset.for_create(
          :upsert,
          %{
            customer_id: b_cust.id,
            step: "vehicle",
            data: %{}
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results} =
        BookingDraft
        |> Ash.Query.set_tenant(ctx.tenant.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end
end
