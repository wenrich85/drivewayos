defmodule DrivewayOSWeb.Auth.ForgotPasswordLiveTest do
  @moduledoc """
  /forgot-password — kicks off AshAuth's reset-token flow.
  Always renders 'check your email' regardless of whether the
  email matched a row, so an attacker can't enumerate accounts.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "fp-#{System.unique_integer([:positive])}",
        display_name: "Forgot Test"
      })
      |> Ash.create(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "real-#{System.unique_integer([:positive])}@example.com",
          password: "Password123!",
          password_confirmation: "Password123!",
          name: "Real User"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    %{tenant: tenant, customer: customer}
  end

  test "form renders + submitting always shows the success state", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, lv, html} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/forgot-password")

    assert html =~ "Reset your password"
    assert html =~ ~s(name="forgot[email]")

    after_html =
      lv
      |> form("#forgot-password-form", %{"forgot" => %{"email" => "anyone@example.com"}})
      |> render_submit()

    assert after_html =~ "is on its way"
  end

  test "real email triggers the password-reset email", %{
    conn: conn,
    tenant: tenant,
    customer: customer
  } do
    {:ok, lv, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/forgot-password")

    lv
    |> form("#forgot-password-form", %{"forgot" => %{"email" => to_string(customer.email)}})
    |> render_submit()

    assert_received {:email, %Swoosh.Email{subject: subject, to: [{_, addr}]}}
    assert subject =~ "Reset your password"
    assert addr == to_string(customer.email)
  end

  test "unknown email shows the same UI but doesn't fire an email", %{
    conn: conn,
    tenant: tenant
  } do
    {:ok, lv, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/forgot-password")

    after_html =
      lv
      |> form("#forgot-password-form", %{
        "forgot" => %{"email" => "ghost-#{System.unique_integer([:positive])}@example.com"}
      })
      |> render_submit()

    # Same success copy regardless.
    assert after_html =~ "is on its way"
    refute_received {:email, _}
  end
end
