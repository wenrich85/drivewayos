defmodule DrivewayOS.Scheduling.BlockTemplateTest do
  @moduledoc """
  Per-tenant recurring schedule templates. A row says "I work
  Wednesdays 9am-12pm; capacity 1". The booking form generates
  concrete slots in a forward window from these.

  V1 scope:
    * Weekly recurring (day_of_week 0-6)
    * One time-of-day window per row, defined by start_time +
      duration_minutes
    * Capacity = how many bookings can share this block on a single
      date (think: two vans → capacity 2)
    * Active/inactive flag so an operator can pause a slot without
      losing the row

  V2 (deferred):
    * Date-specific overrides ("closed on Dec 25 even though
      normally open Wednesdays")
    * Multi-window same day (would just be N rows in V1)
    * Service-type restrictions (this slot only does Deep Clean)
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.Scheduling.BlockTemplate

  require Ash.Query

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "bt-#{System.unique_integer([:positive])}",
        display_name: "Block Test Tenant"
      })
      |> Ash.create(authorize?: false)

    %{tenant: tenant}
  end

  describe "create" do
    test "valid weekly template", %{tenant: tenant} do
      {:ok, bt} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Wednesday morning",
            day_of_week: 3,
            start_time: ~T[09:00:00],
            duration_minutes: 180,
            capacity: 1
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      assert bt.tenant_id == tenant.id
      assert bt.name == "Wednesday morning"
      assert bt.day_of_week == 3
      assert bt.duration_minutes == 180
      assert bt.capacity == 1
      assert bt.active == true
    end

    test "rejects day_of_week outside 0..6", %{tenant: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               BlockTemplate
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Bad",
                   day_of_week: 7,
                   start_time: ~T[09:00:00],
                   duration_minutes: 60,
                   capacity: 1
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end

    test "duration_minutes must be > 0", %{tenant: tenant} do
      assert {:error, %Ash.Error.Invalid{}} =
               BlockTemplate
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   name: "Zero",
                   day_of_week: 1,
                   start_time: ~T[09:00:00],
                   duration_minutes: 0,
                   capacity: 1
                 },
                 tenant: tenant.id
               )
               |> Ash.create(authorize?: false)
    end
  end

  describe ":active read action" do
    test "filters out inactive templates", %{tenant: tenant} do
      {:ok, bt} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "Active",
            day_of_week: 1,
            start_time: ~T[09:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: tenant.id
        )
        |> Ash.create(authorize?: false)

      bt
      |> Ash.Changeset.for_update(:update, %{active: false})
      |> Ash.update!(authorize?: false, tenant: tenant.id)

      {:ok, results} =
        BlockTemplate
        |> Ash.Query.for_read(:active)
        |> Ash.Query.set_tenant(tenant.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end

  describe "tenant isolation" do
    test "tenant A cannot see tenant B's templates", %{tenant: tenant_a} do
      {:ok, tenant_b} =
        Tenant
        |> Ash.Changeset.for_create(:create, %{
          slug: "btb-#{System.unique_integer([:positive])}",
          display_name: "B"
        })
        |> Ash.create(authorize?: false)

      {:ok, _b_template} =
        BlockTemplate
        |> Ash.Changeset.for_create(
          :create,
          %{
            name: "B's slot",
            day_of_week: 1,
            start_time: ~T[10:00:00],
            duration_minutes: 60,
            capacity: 1
          },
          tenant: tenant_b.id
        )
        |> Ash.create(authorize?: false)

      {:ok, results} =
        BlockTemplate
        |> Ash.Query.set_tenant(tenant_a.id)
        |> Ash.read(authorize?: false)

      assert results == []
    end
  end
end
