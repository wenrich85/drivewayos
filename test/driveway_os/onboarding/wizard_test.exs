defmodule DrivewayOS.Onboarding.WizardTest do
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Onboarding.Wizard
  alias DrivewayOS.Platform

  # Fake step modules used to test FSM mechanics in isolation
  # from the real Branding/Services/etc. impls (which arrive in
  # later tasks).
  defmodule FakeAlwaysComplete do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :always_complete
    def title, do: "Always Complete"
    def complete?(_), do: true
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  defmodule FakeNeverComplete do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :never_complete
    def title, do: "Never Complete"
    def complete?(_), do: false
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  defmodule FakeOtherNever do
    @behaviour DrivewayOS.Onboarding.Step
    def id, do: :other_never
    def title, do: "Other Never"
    def complete?(_), do: false
    def render(_), do: nil
    def submit(_, socket), do: {:ok, socket}
  end

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "wiz-#{System.unique_integer([:positive])}",
        display_name: "Wizard Test",
        admin_email: "wiz-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant}
  end

  describe "steps/0" do
    test "returns the canonical step module list in declared order" do
      steps = Wizard.steps()
      assert is_list(steps)
      assert length(steps) == 5
      assert Enum.at(steps, 0) == DrivewayOS.Onboarding.Steps.Branding
      assert Enum.at(steps, 4) == DrivewayOS.Onboarding.Steps.Email
    end
  end

  describe "current_step/2" do
    test "returns nil when all steps are complete", ctx do
      assert Wizard.current_step(ctx.tenant, [FakeAlwaysComplete]) == nil
    end

    test "returns the first non-complete, non-skipped step", ctx do
      assert Wizard.current_step(ctx.tenant, [FakeAlwaysComplete, FakeNeverComplete]) ==
               FakeNeverComplete
    end

    test "skips past steps marked :skipped in wizard_progress", ctx do
      {:ok, with_skip} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{
          step: :never_complete,
          status: :skipped
        })
        |> Ash.update(authorize?: false)

      # never_complete is :skipped, other_never is the next non-complete-non-skipped.
      assert Wizard.current_step(with_skip, [FakeAlwaysComplete, FakeNeverComplete, FakeOtherNever]) ==
               FakeOtherNever
    end
  end

  describe "complete?/2" do
    test "true when all steps are either complete or skipped", ctx do
      {:ok, with_skip} =
        ctx.tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{
          step: :never_complete,
          status: :skipped
        })
        |> Ash.update(authorize?: false)

      assert Wizard.complete?(with_skip, [FakeAlwaysComplete, FakeNeverComplete])
    end

    test "false when at least one step is pending", ctx do
      refute Wizard.complete?(ctx.tenant, [FakeAlwaysComplete, FakeNeverComplete])
    end

    test "true when the step list is empty" do
      assert Wizard.complete?(%{wizard_progress: %{}}, [])
    end
  end

  describe "skip/2 and unskip/2" do
    test "skip writes :skipped to wizard_progress", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :branding)
      assert skipped.wizard_progress == %{"branding" => "skipped"}
    end

    test "unskip removes the key", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :services)
      {:ok, cleared} = Wizard.unskip(skipped, :services)
      assert cleared.wizard_progress == %{}
    end
  end

  describe "skipped?/2" do
    test "true when the step id is in wizard_progress as 'skipped'", ctx do
      {:ok, skipped} = Wizard.skip(ctx.tenant, :payment)
      assert Wizard.skipped?(skipped, :payment)
    end

    test "false when the step id is absent from wizard_progress", ctx do
      refute Wizard.skipped?(ctx.tenant, :branding)
    end

    test "false when the value lacks a wizard_progress key entirely (fallback clause)" do
      refute Wizard.skipped?(%{}, :branding)
      refute Wizard.skipped?(nil, :branding)
    end
  end
end
