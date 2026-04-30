defmodule DrivewayOS.Notifications.PostmarkClientTest do
  use ExUnit.Case, async: true

  import Mox

  alias DrivewayOS.Notifications.PostmarkClient

  setup :verify_on_exit!

  describe "behaviour shape" do
    test "create_server/2 returns {:ok, %{server_id, api_key}} on success" do
      expect(PostmarkClient.Mock, :create_server, fn "test-shop", _opts ->
        {:ok, %{server_id: 12345, api_key: "server-token-abc"}}
      end)

      assert {:ok, %{server_id: 12345, api_key: "server-token-abc"}} =
               PostmarkClient.Mock.create_server("test-shop", [])
    end

    test "create_server/2 returns {:error, reason} on Postmark failure" do
      expect(PostmarkClient.Mock, :create_server, fn _, _ ->
        {:error, %{status: 401, body: %{"Message" => "Invalid token"}}}
      end)

      assert {:error, %{status: 401}} = PostmarkClient.Mock.create_server("test", [])
    end
  end
end
