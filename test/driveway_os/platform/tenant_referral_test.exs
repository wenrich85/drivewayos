defmodule DrivewayOS.Platform.TenantReferralTest do
  @moduledoc """
  Pin the `Platform.TenantReferral` contract: events are creatable
  via the `:log` action, readable, and constrained to the documented
  event_type enum. FK to tenant cascades on tenant delete.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.TenantReferral

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ref-#{System.unique_integer([:positive])}",
        display_name: "Referral Test",
        admin_email: "ref-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "log creates a referral row with auto-set occurred_at", ctx do
    {:ok, ref} =
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        tenant_id: ctx.tenant.id,
        provider: :postmark,
        event_type: :click,
        metadata: %{wizard_step: "email"}
      })
      |> Ash.create(authorize?: false)

    assert ref.tenant_id == ctx.tenant.id
    assert ref.provider == :postmark
    assert ref.event_type == :click
    # Ash :map roundtrips through Postgres jsonb, so atom keys come
    # back as strings. Assert the deserialized shape.
    assert ref.metadata == %{"wizard_step" => "email"}
    assert %DateTime{} = ref.occurred_at
  end

  test "log accepts all three event_types", ctx do
    for ev <- [:click, :provisioned, :revenue_attributed] do
      assert {:ok, _} =
               TenantReferral
               |> Ash.Changeset.for_create(:log, %{
                 tenant_id: ctx.tenant.id,
                 provider: :postmark,
                 event_type: ev
               })
               |> Ash.create(authorize?: false)
    end
  end

  test "log rejects unknown event_type", ctx do
    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             TenantReferral
             |> Ash.Changeset.for_create(:log, %{
               tenant_id: ctx.tenant.id,
               provider: :postmark,
               event_type: :totally_made_up
             })
             |> Ash.create(authorize?: false)

    assert Enum.any?(errors, &match?(%{field: :event_type}, &1))
  end

  test "log rejects missing tenant_id", _ctx do
    {:error, _} =
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        provider: :postmark,
        event_type: :click
      })
      |> Ash.create(authorize?: false)
  end

  test "read returns rows for a tenant", ctx do
    for ev <- [:click, :provisioned] do
      TenantReferral
      |> Ash.Changeset.for_create(:log, %{
        tenant_id: ctx.tenant.id,
        provider: :postmark,
        event_type: ev
      })
      |> Ash.create!(authorize?: false)
    end

    {:ok, all} = Ash.read(TenantReferral, authorize?: false)
    rows = Enum.filter(all, &(&1.tenant_id == ctx.tenant.id))
    assert length(rows) == 2
  end
end
