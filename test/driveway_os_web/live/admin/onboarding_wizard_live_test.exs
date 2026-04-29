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
    test "admin sees a page listing the Stripe Connect provider under Payment", ctx do
      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      # Section header for the :payment category.
      assert html =~ "Payment"
      # The provider's display.title.
      assert html =~ "Take card payments"
      # The provider's display.cta_label inside an anchor with the href.
      assert html =~ ~s(href="/onboarding/stripe/start")
      assert html =~ "Connect Stripe"
    end

    test "providers that are already set up don't render", ctx do
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{stripe_account_id: "acct_done_x"})
      |> Ash.update!(authorize?: false)

      conn = sign_in(ctx.conn, ctx.admin)

      {:ok, _lv, html} =
        conn
        |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me")
        |> live(~p"/admin/onboarding")

      refute html =~ "Connect Stripe"
    end
  end
end
