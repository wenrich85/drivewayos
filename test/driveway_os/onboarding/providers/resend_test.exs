defmodule DrivewayOS.Onboarding.Providers.ResendTest do
  @moduledoc """
  Pin the Resend provider's `Onboarding.Provider` callbacks +
  provision happy path + provision API-error path.

  `provision/2` is API-first (mirrors Phase 1 Postmark): it calls
  ResendClient.create_api_key/1, persists tokens on a new
  EmailConnection row, then sends the welcome email through
  Mailer.for_tenant/1 (which routes to Resend post-Task-7).

  The welcome email IS the deliverability probe — failure surfaces
  at provision-time, not silently at the next booking.
  """
  use DrivewayOS.DataCase, async: false

  import Mox
  import Swoosh.TestAssertions

  alias DrivewayOS.Notifications.ResendClient
  alias DrivewayOS.Onboarding.Providers.Resend
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "rs-#{System.unique_integer([:positive])}",
        display_name: "Resend Provider Test",
        admin_email: "rs-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :resend" do
    assert Resend.id() == :resend
  end

  test "category/0 is :email" do
    assert Resend.category() == :email
  end

  test "configured?/0 false when :resend_api_key unset" do
    Application.delete_env(:driveway_os, :resend_api_key)
    refute Resend.configured?()
  end

  test "configured?/0 true when :resend_api_key set" do
    Application.put_env(:driveway_os, :resend_api_key, "re_master_test")
    on_exit(fn -> Application.delete_env(:driveway_os, :resend_api_key) end)
    assert Resend.configured?()
  end

  test "setup_complete?/1 false when no EmailConnection row", ctx do
    refute Resend.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 true when active EmailConnection exists", ctx do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_1"
    })
    |> Ash.create!(authorize?: false)

    assert Resend.setup_complete?(ctx.tenant)
  end

  test "setup_complete?/1 false after disconnect (api_key cleared)", ctx do
    conn =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_test_1"
      })
      |> Ash.create!(authorize?: false)

    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    refute Resend.setup_complete?(ctx.tenant)
  end

  test "affiliate_config/0 returns nil in V1" do
    # Same posture as Phase 1 Postmark — API-first, no OAuth URL
    # to tag, no enrolled affiliate program.
    assert Resend.affiliate_config() == nil
  end

  test "tenant_perk/0 returns nil in V1" do
    assert Resend.tenant_perk() == nil
  end

  test "provision/2 creates EmailConnection row and sends welcome email", ctx do
    expect(ResendClient.Mock, :create_api_key, fn name ->
      assert name == "drivewayos-#{ctx.tenant.slug}"
      {:ok, %{key_id: "k_test_1", api_key: "re_test_1"}}
    end)

    assert {:ok, _conn} = Resend.provision(ctx.tenant, %{})

    {:ok, conn} = Platform.get_email_connection(ctx.tenant.id, :resend)
    assert conn.external_key_id == "k_test_1"
    assert conn.api_key == "re_test_1"

    assert_email_sent(fn email ->
      assert email.subject == "Your shop is set up to send email"
      assert {_, addr} = hd(email.to)
      assert to_string(addr) == to_string(ctx.admin.email)
    end)
  end

  test "provision/2 surfaces Resend API error, does not create row", ctx do
    expect(ResendClient.Mock, :create_api_key, fn _ ->
      {:error, %{status: 401, body: %{"message" => "Invalid token"}}}
    end)

    assert {:error, %{status: 401}} = Resend.provision(ctx.tenant, %{})

    assert {:error, :not_found} = Platform.get_email_connection(ctx.tenant.id, :resend)
  end
end
