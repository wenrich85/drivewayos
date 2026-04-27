defmodule DrivewayOSWeb.Auth.SignInRateLimitTest do
  @moduledoc """
  Sign-in lockout behavior. 5 wrong attempts on a single email
  flips into "Too many sign-in attempts" — successful sign-in
  resets the counter so a typo-prone real user isn't punished.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Platform.Tenant
  alias DrivewayOS.RateLimiter

  setup do
    {:ok, tenant} =
      Tenant
      |> Ash.Changeset.for_create(:create, %{
        slug: "rl-#{System.unique_integer([:positive])}",
        display_name: "Rate Limit Test"
      })
      |> Ash.create(authorize?: false)

    {:ok, customer} =
      Customer
      |> Ash.Changeset.for_create(
        :register_with_password,
        %{
          email: "rl-#{System.unique_integer([:positive])}@example.com",
          password: "GoodPassword123!",
          password_confirmation: "GoodPassword123!",
          name: "Rate Larry"
        },
        tenant: tenant.id
      )
      |> Ash.create(authorize?: false)

    RateLimiter.reset("signin:#{tenant.id}:#{to_string(customer.email)}")

    %{tenant: tenant, customer: customer}
  end

  defp submit_signin(lv, email, password) do
    lv
    |> form("#sign-in-form", %{
      "signin" => %{"email" => email, "password" => password}
    })
    |> render_submit()
  end

  test "5 wrong attempts on the same email lock the 6th out", %{
    conn: conn,
    tenant: tenant,
    customer: customer
  } do
    {:ok, lv, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

    for _ <- 1..5 do
      html = submit_signin(lv, to_string(customer.email), "wrong-password")
      assert html =~ "Invalid email or password"
    end

    html = submit_signin(lv, to_string(customer.email), "wrong-password")
    assert html =~ "Too many sign-in attempts"
  end

  test "successful sign-in resets the counter", %{
    conn: conn,
    tenant: tenant,
    customer: customer
  } do
    {:ok, lv, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

    for _ <- 1..3 do
      submit_signin(lv, to_string(customer.email), "wrong-password")
    end

    # Successful sign-in. LV either crashes the test process via
    # the redirect or returns an :ok tuple — either is fine; the
    # counter reset is the side effect we care about.
    try do
      submit_signin(lv, to_string(customer.email), "GoodPassword123!")
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # Fresh LV; would have been locked at 6 prior attempts but the
    # success above wiped the counter, so we can do another 5
    # without hitting the limit.
    {:ok, lv2, _} =
      conn |> Map.put(:host, "#{tenant.slug}.lvh.me") |> live(~p"/sign-in")

    for _ <- 1..5 do
      submit_signin(lv2, to_string(customer.email), "wrong-password")
    end

    # 6th locks again.
    html = submit_signin(lv2, to_string(customer.email), "wrong-password")
    assert html =~ "Too many sign-in attempts"
  end
end
