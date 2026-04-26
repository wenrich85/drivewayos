defmodule DrivewayOSWeb.Platform.MetricsLiveTest do
  @moduledoc """
  Platform admin → cross-tenant SaaS metrics at admin.lvh.me/metrics.

  Reads aggregate stats across every tenant (sum of paid appointment
  prices = GMV; platform fee = 10% of that = our revenue).

  Auth: PlatformUser only.
  """
  use DrivewayOSWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.PlatformUser
  alias DrivewayOS.Scheduling.{Appointment, ServiceType}

  require Ash.Query

  setup do
    {:ok, %{tenant: tenant_a, admin: admin_a}} =
      Platform.provision_tenant(%{
        slug: "mt-a-#{System.unique_integer([:positive])}",
        display_name: "Metrics A",
        admin_email: "ma-#{System.unique_integer([:positive])}@example.com",
        admin_name: "MA",
        admin_password: "Password123!"
      })

    # Mark connected so we can prove the "connected count" stat.
    tenant_a
    |> Ash.Changeset.for_update(:update, %{
      stripe_account_id: "acct_metrics_test_#{System.unique_integer([:positive])}",
      stripe_account_status: :enabled,
      status: :active
    })
    |> Ash.update!(authorize?: false)

    {:ok, [service_a | _]} =
      ServiceType |> Ash.Query.set_tenant(tenant_a.id) |> Ash.read(authorize?: false)

    # Create a paid appointment so GMV > 0
    {:ok, appt} =
      Appointment
      |> Ash.Changeset.for_create(
        :book,
        %{
          customer_id: admin_a.id,
          service_type_id: service_a.id,
          scheduled_at:
            DateTime.utc_now() |> DateTime.add(86_400, :second) |> DateTime.truncate(:second),
          duration_minutes: service_a.duration_minutes,
          price_cents: service_a.base_price_cents,
          vehicle_description: "X",
          service_address: "Y"
        },
        tenant: tenant_a.id
      )
      |> Ash.create(authorize?: false)

    appt
    |> Ash.Changeset.for_update(:mark_paid, %{stripe_payment_intent_id: "pi_test"})
    |> Ash.update!(authorize?: false, tenant: tenant_a.id)

    {:ok, platform_user} =
      PlatformUser
      |> Ash.Changeset.for_create(:register_with_password, %{
        email: "mtop-#{System.unique_integer([:positive])}@drivewayos.com",
        password: "Password123!",
        password_confirmation: "Password123!",
        name: "Op"
      })
      |> Ash.create(authorize?: false)

    %{platform_user: platform_user, gmv_cents: service_a.base_price_cents}
  end

  defp sign_in_platform(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    conn |> Plug.Test.init_test_session(%{platform_token: token})
  end

  test "auth gate: no platform user → redirect", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/platform-sign-in"}}} =
             conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/metrics")
  end

  test "renders the metric cards", %{conn: conn, platform_user: pu, gmv_cents: gmv} do
    conn = sign_in_platform(conn, pu)

    {:ok, _lv, html} =
      conn |> Map.put(:host, "admin.lvh.me") |> live(~p"/metrics")

    assert html =~ "Metrics"
    assert html =~ "GMV"
    # GMV figure is the price as dollars
    expected = "$" <> :erlang.float_to_binary(gmv / 100, decimals: 2)
    assert html =~ expected
  end
end
