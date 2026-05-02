defmodule DrivewayOS.Onboarding.Steps.PaymentTest do
  @moduledoc """
  Steps.Payment is a thin presentational delegator over the
  StripeConnect provider — the heavy lifting (OAuth dance + account
  status) is exercised in the StripeConnect provider's own suite.
  These tests pin the contract: the right id/title/done predicate,
  and `submit/2` as a no-op (the actual provisioning happens out of
  band via Stripe's hosted redirect).
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Payment, as: Step
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "pmt-#{System.unique_integer([:positive])}",
        display_name: "Payment Step Test",
        admin_email: "pmt-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :payment" do
    assert Step.id() == :payment
  end

  test "title/0 mirrors the StripeConnect provider's display title" do
    assert Step.title() == "Take card payments"
  end

  test "complete?/1 false when tenant has no stripe_account_id", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once stripe_account_id is set", ctx do
    {:ok, with_stripe} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_test_123"})
      |> Ash.update(authorize?: false)

    assert Step.complete?(with_stripe)
  end

  test "submit/2 is a no-op — provisioning happens via Stripe's hosted redirect", ctx do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_tenant: ctx.tenant,
        errors: %{}
      }
    }

    assert {:ok, ^socket} = Step.submit(%{}, socket)
  end

  test "render/1 emits the StripeConnect blurb + Connect button" do
    html =
      Step.render(%{__changed__: %{}})
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "Connect Stripe"
    assert html =~ "/onboarding/stripe/start"
  end

  describe "render/1 perk copy" do
    test "does not render perk paragraph when StripeConnect.tenant_perk/0 is nil (V1 default)" do
      html =
        Step.render(%{__changed__: %{}})
        |> Phoenix.LiveViewTest.rendered_to_string()

      # V1: StripeConnect.tenant_perk/0 returns nil. The success-text
      # class shouldn't appear in the DOM. Once a provider returns a
      # non-nil string, this regression flips and the if-let branch
      # renders.
      refute html =~ "text-success"
    end
  end
end
