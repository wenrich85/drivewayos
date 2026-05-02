defmodule DrivewayOS.Onboarding.Steps.EmailTest do
  use DrivewayOS.DataCase, async: false

  import Mox

  alias DrivewayOS.Onboarding.Steps.Email, as: Step
  alias DrivewayOS.Notifications.PostmarkClient
  alias DrivewayOS.Platform

  setup :verify_on_exit!

  setup do
    {:ok, %{tenant: tenant, admin: admin}} =
      Platform.provision_tenant(%{
        slug: "em-#{System.unique_integer([:positive])}",
        display_name: "Email Step Test",
        admin_email: "em-#{System.unique_integer([:positive])}@example.com",
        admin_name: "Owner",
        admin_password: "Password123!"
      })

    %{tenant: tenant, admin: admin}
  end

  test "id/0 is :email" do
    assert Step.id() == :email
  end

  test "complete?/1 false when tenant has no postmark_server_id", ctx do
    refute Step.complete?(ctx.tenant)
  end

  test "submit/2 happy path: provisions Postmark and updates the socket", ctx do
    expect(PostmarkClient.Mock, :create_server, fn _name, _opts ->
      {:ok, %{server_id: 88_001, api_key: "server-token-pq"}}
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_tenant: ctx.tenant,
        current_customer: ctx.admin,
        errors: %{}
      }
    }

    assert {:ok, socket} = Step.submit(%{}, socket)
    assert socket.assigns.current_tenant.postmark_server_id == "88001"
  end

  test "submit/2 surfaces Postmark API error", ctx do
    expect(PostmarkClient.Mock, :create_server, fn _, _ ->
      {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
    end)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, current_tenant: ctx.tenant, current_customer: ctx.admin, errors: %{}}
    }

    assert {:error, _} = Step.submit(%{}, socket)
  end
end
