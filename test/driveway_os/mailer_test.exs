defmodule DrivewayOS.MailerTest do
  @moduledoc """
  Pin the `Mailer.for_tenant/1` routing precedence:

    1. Active EmailConnection{:resend} → Swoosh.Adapters.Resend opts.
    2. Tenant.postmark_api_key → Swoosh.Adapters.Postmark opts.
    3. Neither → [].

  Plus the test-mode override: when `:swoosh, :api_client` is
  false (the test suite's default), `for_tenant/1` returns []
  regardless of credentials so Phase 1's Swoosh.Adapters.Test
  capture path stays in place.
  """
  use DrivewayOS.DataCase, async: false

  alias DrivewayOS.Mailer
  alias DrivewayOS.Platform
  alias DrivewayOS.Platform.EmailConnection

  setup do
    {:ok, %{tenant: tenant}} =
      Platform.provision_tenant(%{
        slug: "ml-#{System.unique_integer([:positive])}",
        display_name: "Mailer Test",
        admin_email: "ml-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    # Force api_client on for these tests so we exercise the routing
    # paths instead of the test-mode override.
    prev = Application.get_env(:swoosh, :api_client)
    Application.put_env(:swoosh, :api_client, true)
    on_exit(fn -> Application.put_env(:swoosh, :api_client, prev) end)

    %{tenant: tenant}
  end

  test "returns [] when no email provider is connected", ctx do
    assert Mailer.for_tenant(ctx.tenant) == []
  end

  test "routes to Postmark when only postmark_api_key is set", ctx do
    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    opts = Mailer.for_tenant(t)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Postmark
    assert Keyword.get(opts, :api_key) == "server-token-pq"
  end

  test "routes to Resend when active EmailConnection{:resend} exists", ctx do
    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_active"
    })
    |> Ash.create!(authorize?: false)

    opts = Mailer.for_tenant(ctx.tenant)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Resend
    assert Keyword.get(opts, :api_key) == "re_test_active"
  end

  test "Resend takes precedence over Postmark when both are present", ctx do
    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: t.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_test_resend_wins"
    })
    |> Ash.create!(authorize?: false)

    opts = Mailer.for_tenant(t)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Resend
    assert Keyword.get(opts, :api_key) == "re_test_resend_wins"
  end

  test "skips Resend EmailConnection when paused (auto_send_enabled false)", ctx do
    conn =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_paused"
      })
      |> Ash.create!(authorize?: false)

    conn |> Ash.Changeset.for_update(:pause, %{}) |> Ash.update!(authorize?: false)

    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    opts = Mailer.for_tenant(t)
    # Falls through to Postmark since the Resend conn is paused.
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Postmark
  end

  test "skips Resend EmailConnection when disconnected", ctx do
    conn =
      EmailConnection
      |> Ash.Changeset.for_create(:connect, %{
        tenant_id: ctx.tenant.id,
        provider: :resend,
        external_key_id: "k1",
        api_key: "re_disc"
      })
      |> Ash.create!(authorize?: false)

    conn |> Ash.Changeset.for_update(:disconnect, %{}) |> Ash.update!(authorize?: false)

    assert Mailer.for_tenant(ctx.tenant) == []
  end

  test "test-mode override: returns [] when :swoosh :api_client is false", ctx do
    Application.put_env(:swoosh, :api_client, false)

    {:ok, t} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_api_key: "server-token-pq"})
      |> Ash.update(authorize?: false)

    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: t.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_x"
    })
    |> Ash.create!(authorize?: false)

    # Even with both connected, the test-mode override suppresses.
    assert Mailer.for_tenant(t) == []
  end

  test "production path: module-atom api_client falls through to routing logic", ctx do
    Application.put_env(:swoosh, :api_client, Swoosh.ApiClient.Req)

    EmailConnection
    |> Ash.Changeset.for_create(:connect, %{
      tenant_id: ctx.tenant.id,
      provider: :resend,
      external_key_id: "k1",
      api_key: "re_prod_path"
    })
    |> Ash.create!(authorize?: false)

    # Must NOT raise ArgumentError. Must route to Resend.
    opts = Mailer.for_tenant(ctx.tenant)
    assert Keyword.get(opts, :adapter) == Swoosh.Adapters.Resend
    assert Keyword.get(opts, :api_key) == "re_prod_path"
  end
end
