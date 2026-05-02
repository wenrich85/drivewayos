defmodule DrivewayOS.Onboarding.Steps.BrandingTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Branding
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "br-#{System.unique_integer([:positive])}",
        display_name: "Branding Step Test",
        admin_email: "br-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :branding" do
    assert Branding.id() == :branding
  end

  test "title/0 is human-readable" do
    assert is_binary(Branding.title())
  end

  test "complete?/1 false when support_email is nil", ctx do
    refute Branding.complete?(ctx.tenant)
  end

  test "complete?/1 true once support_email is set", ctx do
    {:ok, with_email} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{support_email: "support@acme.test"})
      |> Ash.update(authorize?: false)

    assert Branding.complete?(with_email)
  end
end
