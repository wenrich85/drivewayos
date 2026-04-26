defmodule DrivewayOSWeb.Auth.MagicLinkLiveTest do
  @moduledoc """
  Magic-link sign-in for customers. Lives at
  `{slug}.lvh.me/magic-link`.

  Flow:
    1. Customer enters email
    2. We look them up in the current tenant
    3. If found, mint a short-lived JWT + email a sign-in link
    4. Always show the same "check your email" message — don't
       leak whether the address exists in this tenant

  The link click lands at `/auth/customer/magic-link?token=...`,
  which is handled by Auth.SessionController — already covered by
  the existing store_token controller because magic-link tokens
  are just regular customer JWTs.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Swoosh.TestAssertions

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform

  setup do
    {:ok, %{tenant: tenant, admin: _}} =
      Platform.provision_tenant(%{
        slug: "ml-#{System.unique_integer([:positive])}",
        display_name: "Magic Link Shop",
        admin_email: "ml-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    email = "alice-#{System.unique_integer([:positive])}@example.com"

    {:ok, alice} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: email,
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Alice"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, alice: alice, alice_email: email}
  end

  describe "render" do
    test "shows the form on tenant subdomain", %{conn: conn, tenant: tenant} do
      {:ok, _lv, html} =
        conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/magic-link")

      assert html =~ "Email me a sign-in link"
      assert html =~ ~s(name="signin[email]")
    end

    test "marketing host: bounces to /", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/"}}} =
               conn |> Map.put(:host, "lvh.me") |> live(~p"/magic-link")
    end
  end

  describe "submit" do
    test "known email: success message + email sent", ctx do
      {:ok, lv, _} =
        ctx.conn |> Map.put(:host, "#{ctx.tenant.slug}.lvh.me") |> live(~p"/magic-link")

      html =
        lv
        |> form("#magic-link-form", %{"signin" => %{"email" => ctx.alice_email}})
        |> render_submit()

      assert html =~ "Check your email"

      assert_email_sent(fn email ->
        assert email.to == [{ctx.alice.name, ctx.alice_email}]
        assert email.subject =~ "sign-in"
        # The link points at the existing store-token controller —
        # magic-link tokens are just regular customer JWTs, so we
        # reuse that endpoint instead of building a new one.
        assert email.text_body =~ "/auth/customer/store-token"
        assert email.text_body =~ "?token="
      end)
    end

    test "unknown email: same success message, no email sent",
         %{conn: conn, tenant: tenant} do
      {:ok, lv, _} = conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/magic-link")

      html =
        lv
        |> form("#magic-link-form", %{"signin" => %{"email" => "nobody@example.com"}})
        |> render_submit()

      assert html =~ "Check your email"

      # No email goes out — we don't leak whether the address exists.
      assert_no_email_sent()
    end

    test "cross-tenant: email-on-tenant-A submitted on tenant B → no email",
         ctx do
      {:ok, %{tenant: tenant_b}} =
        Platform.provision_tenant(%{
          slug: "mlb-#{System.unique_integer([:positive])}",
          display_name: "B",
          admin_email: "mlb-#{System.unique_integer([:positive])}@example.com",
          admin_name: "B",
          admin_password: "Password123!"
        })

      {:ok, lv, _} =
        ctx.conn |> Map.put(:host, "#{tenant_b.slug}.lvh.me") |> live(~p"/magic-link")

      lv
      |> form("#magic-link-form", %{"signin" => %{"email" => ctx.alice_email}})
      |> render_submit()

      # Alice is on tenant A; tenant B's lookup finds nothing.
      assert_no_email_sent()
    end
  end
end
