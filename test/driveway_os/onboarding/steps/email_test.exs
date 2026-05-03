defmodule DrivewayOS.Onboarding.Steps.EmailTest do
  @moduledoc """
  Steps.Email is the wizard's email step. As of Phase 4b, generic
  over N providers in the `:email` category — renders side-by-side
  cards for each configured + not-yet-set-up provider (Postmark +
  Resend in V1). `complete?/1` returns true if ANY email provider is
  connected. Provisioning happens in the per-provider controllers
  (PostmarkOnboardingController + ResendOnboardingController);
  these tests pin the picker render + complete predicate + no-op
  submit/2.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Steps.Email, as: Step
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "em-#{System.unique_integer([:positive])}",
        display_name: "Email Step Test",
        admin_email: "em-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  test "id/0 is :email" do
    assert Step.id() == :email
  end

  test "title/0 is the email step heading" do
    assert Step.title() == "Send booking emails"
  end

  test "complete?/1 false when tenant has no email provider connected", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "complete?/1 true once Postmark is connected", ctx do
    {:ok, with_pm} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{
        postmark_server_id: "88001",
        postmark_api_key: "server-token-pq"
      })
      |> Ash.update(authorize?: false)

    assert Step.complete?(with_pm)
  end

  test "complete?/1 true once Resend EmailConnection exists", ctx do
    DrivewayOS.Platform.EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_x"
    })
    |> Ash.create!(authorize?: false)

    assert Step.complete?(ctx.tenant)
  end

  test "submit/2 is a no-op — provisioning happens via the per-provider controller", ctx do
    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_tenant: ctx.tenant,
        errors: %{}
      }
    }

    assert {:ok, ^socket} = Step.submit(%{}, socket)
  end

  describe "render/1 picker (multi-provider)" do
    setup do
      Application.put_env(:driveway_os, :postmark_account_token, "pt_master_test")
      Application.put_env(:driveway_os, :resend_api_key, "re_master_test")

      on_exit(fn ->
        Application.delete_env(:driveway_os, :postmark_account_token)
        Application.delete_env(:driveway_os, :resend_api_key)
      end)

      :ok
    end

    test "renders cards for every configured email provider not yet set up", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      # Both V1 email providers visible.
      assert html =~ "Set up email"
      assert html =~ "Set up Resend"
    end

    test "applies UX rules: 44px touch targets, motion-reduce, slate-600 text", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "min-h-[44px]"
      assert html =~ "motion-reduce:transition-none"
      assert html =~ "text-slate-600"
    end

    test "Postmark card href routes to /onboarding/postmark/start", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "/onboarding/postmark/start"
    end

    test "Resend card href routes to /onboarding/resend/start", ctx do
      html =
        Step.render(%{__changed__: %{}, current_tenant: ctx.tenant})
        |> Phoenix.LiveViewTest.rendered_to_string()

      assert html =~ "/onboarding/resend/start"
    end
  end
end
