defmodule DrivewayOSWeb.Auth.ResetPasswordLiveTest do
  @moduledoc """
  /reset-password/:token — submit + persist new password + auto
  sign in. Token is whatever
  AshAuthentication.Strategy.Password.reset_token_for/1 mints.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "rp-#{System.unique_integer([:positive])}",
        display_name: "Reset Test"
      })
      |> Ash.create(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "rp-#{System.unique_integer([:positive])}@example.com",
          password: "OldPassword123!",
          password_confirmation: "OldPassword123!",
          name: "Reset Larry"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    {:ok, strategy} = AshAuthentication.Info.strategy(Customer, :password)
    {:ok, token} = AshAuthentication.Strategy.Password.reset_token_for(strategy, customer)

    %{tenant: tenant, customer: customer, token: token}
  end

  test "valid token + matching passwords flips the hashed_password", %{
    conn: conn,
    tenant: tenant,
    customer: customer,
    token: token
  } do
    {:ok, lv, html} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/reset-password/#{token}")

    assert html =~ "Set a new password"

    lv
    |> form("#reset-password-form", %{
      "reset" => %{
        "password" => "BrandNewPassword123!",
        "password_confirmation" => "BrandNewPassword123!"
      }
    })
    |> render_submit()

    # Old password should no longer authenticate.
    assert {:error, _} =
             Customer
             |> Ash.Query.for_read(
               :sign_in_with_password,
               %{email: to_string(customer.email), password: "OldPassword123!"},
               tenant: tenant.id
             )
             |> Ash.read_one(authorize?: false)

    # New password authenticates fine.
    assert {:ok, _} =
             Customer
             |> Ash.Query.for_read(
               :sign_in_with_password,
               %{
                 email: to_string(customer.email),
                 password: "BrandNewPassword123!"
               },
               tenant: tenant.id
             )
             |> Ash.read_one(authorize?: false)
  end

  test "invalid token shows the friendly error", %{conn: conn, tenant: tenant} do
    {:ok, lv, _} =
      conn
      |> Map.put(:host, "#{tenant.slug}.lvh.me")
      |> live(~p"/reset-password/not-a-real-token")

    html =
      lv
      |> form("#reset-password-form", %{
        "reset" => %{
          "password" => "WhateverPassword123!",
          "password_confirmation" => "WhateverPassword123!"
        }
      })
      |> render_submit()

    assert html =~ "invalid or expired"
  end

  test "mismatched passwords surface a field error", %{
    conn: conn,
    tenant: tenant,
    token: token
  } do
    {:ok, lv, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/reset-password/#{token}")

    html =
      lv
      |> form("#reset-password-form", %{
        "reset" => %{
          "password" => "BrandNewPassword123!",
          "password_confirmation" => "DifferentPassword123!"
        }
      })
      |> render_submit()

    assert html =~ "match" or html =~ "confirmation"
  end

  require Ash.Query
end
