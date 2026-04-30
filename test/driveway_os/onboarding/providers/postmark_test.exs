defmodule DrivewayOS.Onboarding.Providers.PostmarkTest do
  use DrivewayOS.DataCase, async: false

  import Mox
  import Swoosh.TestAssertions

  alias DrivewayOS.Onboarding.Providers.Postmark, as: Provider
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "pm-#{System.unique_integer([:positive])}",
        display_name: "Postmark Test",
        admin_email: "pm-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :postmark" do
    assert Provider.id() == :postmark
  end

  test "category/0 is :email" do
    assert Provider.category() == :email
  end

  test "display/0 returns the canonical card copy" do
    d = Provider.display()
    assert d.title == "Send booking emails"
    assert d.cta_label == "Set up email"
    assert d.href == "/admin/onboarding"
  end

  test "configured?/0 mirrors POSTMARK_ACCOUNT_TOKEN env" do
    original = Application.get_env(:driveway_os, :postmark_account_token)

    Application.put_env(:driveway_os, :postmark_account_token, "abc")
    assert Provider.configured?()

    Application.put_env(:driveway_os, :postmark_account_token, "")
    refute Provider.configured?()

    on_exit(fn -> Application.put_env(:driveway_os, :postmark_account_token, original) end)
  end

  test "setup_complete?/1 reflects postmark_server_id presence", ctx do
    refute Provider.setup_complete?(ctx.tenant)

    {:ok, with_server} =
      ctx.tenant
      |> Ash.Changeset.for_update(:update, %{postmark_server_id: "12345"})
      |> Ash.update(authorize?: false)

    assert Provider.setup_complete?(with_server)
  end

  describe "provision/2" do
    test "happy path: creates server, persists creds, sends welcome email", ctx do
      expect(PostmarkClient.Mock, :create_server, fn name, _opts ->
        assert name == "drivewayos-#{ctx.tenant.slug}"
        {:ok, %{server_id: 99_001, api_key: "server-token-xyz"}}
      end)

      assert {:ok, updated} = Provider.provision(ctx.tenant, %{})
      assert updated.postmark_server_id == "99001"
      assert updated.postmark_api_key == "server-token-xyz"

      assert_email_sent(fn email ->
        assert email.subject =~ "set up to send email"
        assert email.to == [{ctx.admin.name, to_string(ctx.admin.email)}]
      end)
    end

    test "Postmark API error: returns {:error, reason} without persisting", ctx do
      expect(PostmarkClient.Mock, :create_server, fn _, _ ->
        {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
      end)

      assert {:error, %{status: 401}} = Provider.provision(ctx.tenant, %{})

      reloaded = Ash.get!(DrivewayOS.Platform.Tenant, ctx.tenant.id, authorize?: false)
      assert reloaded.postmark_server_id == nil
      assert reloaded.postmark_api_key == nil
    end
  end
end
