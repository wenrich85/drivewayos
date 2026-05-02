defmodule DrivewayOS.Onboarding.Steps.ScheduleTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Schedule, as: Step
  alias DrivewayOS.Platform
  alias DrivewayOS.Scheduling.BlockTemplate

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "sc-#{System.unique_integer([:positive])}",
        display_name: "Schedule Step Test",
        admin_email: "sc-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :schedule" do
    assert Step.id() == :schedule
  end

  test "complete?/1 false when tenant has no block templates", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once at least one BlockTemplate exists", ctx do
    BlockTemplate
    |> Ash.Changeset.for_create(
      :create,
      %{
        name: "Monday Morning",
        day_of_week: 1,
        start_time: ~T[09:00:00],
        duration_minutes: 480
      },
      tenant: ctx.tenant.id
    )
    |> Ash.create!(authorize?: false)

    assert Step.complete?(ctx.tenant)
  end
end
