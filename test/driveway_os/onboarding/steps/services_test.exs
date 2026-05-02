defmodule DrivewayOS.Onboarding.Steps.ServicesTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Services, as: Step
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.ServiceType

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sv-#{System.unique_integer([:positive])}",
        display_name: "Services Step Test",
        admin_email: "sv-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :services" do
    assert Step.id() == :services
  end

  test "complete?/1 false for a fresh tenant with default seeds", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once a default service is renamed", ctx do
    {:ok, [first | _]} =
      ServiceType
      |> Ash.Query.set_tenant(ctx.tenant.id)
      |> Ash.read(authorize?: false)

    first
    |> Ash.Changeset.for_update(:update, %{slug: "express-wash", name: "Express Wash"})
    |> Ash.update!(authorize?: false, tenant: ctx.tenant.id)

    reloaded =
      Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)

    assert Step.complete?(reloaded)
  end
end
