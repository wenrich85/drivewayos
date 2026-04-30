defmodule DrivewayOS.Notifications.PostmarkClient do
  @moduledoc """
  Behaviour for talking to the Postmark API. Defined as a behaviour
  so tests can use Mox to bypass HTTP and assert on the calls
  Postmark.provision/2 makes.

  The concrete HTTP impl lives in
  `DrivewayOS.Notifications.PostmarkClient.Http`. Tests configure
  `Mox.defmock` for `DrivewayOS.Notifications.PostmarkClient.Mock`
  in `test_helper.exs`.

  Resolve the runtime impl via `client/0` — in dev/prod that's the
  HTTP module; in test it's the Mox.
  """

  alias DrivewayOS.Notifications.PostmarkClient.Http

  @doc """
  Create a Postmark Server scoped to one DrivewayOS tenant.
  Returns {:ok, %{server_id: integer, api_key: binary}} on success.
  Returns {:error, %{status: integer, body: term}} on HTTP error.
  """
  @callback create_server(name :: String.t(), opts :: keyword()) ::
              {:ok, %{server_id: integer(), api_key: String.t()}}
              | {:error, term()}

  @doc "Resolve the configured client module (HTTP in prod, Mock in test)."
  @spec client() :: module()
  def client do
    Application.get_env(:driveway_os, :postmark_client, Http)
  end

  @doc "Convenience wrapper that delegates to the configured client."
  @spec create_server(String.t(), keyword()) ::
          {:ok, %{server_id: integer(), api_key: String.t()}} | {:error, term()}
  def create_server(name, opts \\ []), do: client().create_server(name, opts)
end
