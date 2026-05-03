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

  test "render/1 emits the StripeConnect blurb + Connect button", ctx do
    html =
      Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
      |> Phoenix.LiveViewTest.rendered_to_string()

    assert html =~ "Connect Stripe"
    assert html =~ "/onboarding/stripe/start"
  end

  describe "render/1 perk copy" do
    setup do
      {:ok, %{tenant: tenant}} =
        Platform.provision_tenant(%{
          slug: "pmt-perk-#{System.unique_integer([:positive])}",
          display_name: "Payment Perk Test",
          admin_email: "pmt-perk-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "does not render perk paragraph when no payment provider exposes tenant_perk/0 (V1 default)",
         ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      # V1: neither StripeConnect nor Square return non-nil from
      # tenant_perk/0. The success-text class shouldn't appear in the
      # DOM. Once any provider returns a non-nil string, this
      # regression flips and the if-let branch renders.
      refute html =~ "text-success"
    end
  end

  describe "render/1 picker (multi-provider)" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "spp-#{System.unique_integer([:positive])}",
          display_name: "Picker Test",
          admin_email: "spp-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "renders cards for every configured payment provider not yet set up", ctx do
      html =
        Step.render(%{
          __changed__: %{},
          current_tenant: ctx.tenant
        })
        |> Phoenix.LiveViewTest.rendered_to_string()

      # Both V1 payment providers should be visible (Stripe Connect + Square)
      assert html =~ "Connect Stripe"
      assert html =~ "Connect Square"
    end

    test "applies UX rules: 44px touch targets, motion-reduce, slate-600 text", ctx do
      html =
        Step.render(%{
          __changed__: %{},
          current_tenant: ctx.tenant
        })
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "min-h-[44px]"
      assert html =~ "motion-reduce:transition-none"
      assert html =~ "text-slate-600"
    end
  end

  describe "complete?/1 generalization" do
    setup do
      {:ok, %{tenant: tenant}} =
        DrivewayOS.Platform.provision_tenant(%{
          slug: "spc-#{System.unique_integer([:positive])}",
          display_name: "Complete Test",
          admin_email: "spc-#{System.unique_integer([:positive])}@example.com",
          admin_name: "Owner",
          admin_password: "Password123!"
        })

      %{tenant: tenant}
    end

    test "false when no payment provider connected", ctx do
      refute Step.complete?(ctx.tenant)
    end

    test "true when Stripe is connected", ctx do
      {:ok, t} =
        ctx.tenant
        |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_test_123"})
        |> Ash.update(authorize?: false)

      assert Step.complete?(t)
    end

    test "true when Square is connected (PaymentConnection)", ctx do
      {:ok, _} =
        DrivewayOS.Platform.PaymentConnection
        |> Ash.Changeset.for_create(:connect, %{
          tenant_id: ctx.tenant.id,
          provider: :square,
          external_merchant_id: "MLR-1",
          access_token: "at",
          refresh_token: "rt",
          access_token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        })
        |> Ash.create(authorize?: false)

      assert Step.complete?(ctx.tenant)
    end
  end
end
