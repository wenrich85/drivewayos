defmodule DrivewayOS.Notifications.ResendClientTest do
  @moduledoc """
  Pin the `ResendClient` behaviour resolver: `client/0` returns the
  configured impl (Mox in test, Http in prod). The convenience
  wrappers (`create_api_key/1`, `delete_api_key/1`) delegate to the
  configured impl, so tests Mox-stub the behaviour and assert the
  Resend.provision/2 call site routes through correctly.
  """
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Notifications.ResendClient

  setup :verify_on_exit!

  test "client/0 returns the configured impl (Mock in test)" do
    assert ResendClient.client() == DrivewayOS.Notifications.ResendClient.Mock
  end

  test "create_api_key/1 delegates to the configured client" do
    expect(ResendClient.Mock, :create_api_key, fn "tenant-name" ->
      {:ok, %{key_id: "k1", api_key: "re_x"}}
    end)

    assert {:ok, %{key_id: "k1", api_key: "re_x"}} =
             ResendClient.create_api_key("tenant-name")
  end

  test "delete_api_key/1 delegates to the configured client" do
    expect(ResendClient.Mock, :delete_api_key, fn "k1" -> :ok end)

    assert :ok = ResendClient.delete_api_key("k1")
  end
end
