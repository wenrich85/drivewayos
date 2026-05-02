defmodule DrivewayOSWeb.Admin.OnboardingWizardLiveTest do
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "onb-#{System.unique_integer([:positive])}",
        display_name: "Onboarding Test",
        admin_email: "onb-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    {:ok, regular} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "reg-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Regular"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, admin: admin, regular: regular}
  end

  defp sign_in(conn, customer) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(customer)
    Plug.Test.init_test_session(conn, %{customer_token: token})
  end

  describe "auth" do
    test "anonymous → /sign-in", %{conn: conn, tenant: tenant} do
      assert {:error, {:live_redirect, %{to: "/sign-in"}}} =
               conn
               |> Map.put(:host, "#{tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end

    test "non-admin customer → /", ctx do
      conn = sign_in(ctx.conn, ctx.regular)

      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end
  end

  describe "rendering" do
    test "admin lands on the Branding step on a fresh tenant", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      assert html =~ "Step 1 of 5"
      assert html =~ "Make it yours"
    end
  end

  describe "linear flow" do
    test "fresh tenant lands on the Branding step", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      assert html =~ "Make it yours"
      assert html =~ "Support email"
    end

    test "submitting Branding form advances to Services", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      html =
        lv
        |> form("#step-branding-form", %{
          "branding" => %{"support_email" => "hello@acme.test"}
        })
        |> render_submit()

      # After submit, the next pending step is Services (default
      # seeded services unchanged → Services.complete?/1 = false).
      assert html =~ "Set your service menu"
    end

    test "Skip-for-now marks step skipped + advances", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, lv, _} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      html = render_click(lv, "skip_step", %{"step" => "branding"})

      reloaded =
        Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)

      assert reloaded.wizard_progress == %{"branding" => "skipped"}
      assert html =~ "Set your service menu"
    end

    test "wizard redirects to /admin when all steps are complete or skipped", ctx do
      # Mark every step as skipped (cheapest way to satisfy Wizard.complete?/1).
      # Chain updates so each iteration reads the latest wizard_progress.
      Enum.reduce([:branding, :services, :schedule, :payment, :email], ctx.tenant, fn step_id, tenant ->
        tenant
        |> Ash.Changeset.for_update(:set_wizard_progress, %{step: step_id, status: :skipped})
        |> Ash.update!(authorize?: false)
      end)

      conn = sign_in(ctx.conn, ctx.admin)

      assert {:error, {:live_redirect, %{to: "/admin"}}} =
               conn
               |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
               |> live(~p"/admin/onboarding")
    end
  end
end
