defmodule DrivewayOS.Notifications.ResendClient do
  @moduledoc """
  Behaviour for talking to the Resend API. Defined as a behaviour
  so tests can use Mox to bypass HTTP and assert on the calls
  Resend.provision/2 makes.

  The concrete HTTP impl lives in
  `DrivewayOS.Notifications.ResendClient.Http`. Tests configure
  `Mox.defmock` for `DrivewayOS.Notifications.ResendClient.Mock`
  in `test_helper.exs`.

  Resolve the runtime impl via `client/0` — in dev/prod that's the
  HTTP module; in test it's the Mox.
  """

  alias DrivewayOS.Notifications.ResendClient.Http

  @doc """
  Create a Resend API key scoped to one DrivewayOS tenant. Returns
  `{:ok, %{key_id: binary, api_key: binary}}` on success. Returns
  `{:error, %{status: integer, body: term}}` on HTTP error.
  """
  @callback create_api_key(name :: String.t()) ::
              {:ok, %{key_id: String.t(), api_key: String.t()}}
              | {:error, term()}

  @doc """
  Delete a Resend API key (used during disconnect). Returns `:ok` on
  success or `{:error, term}` on failure.
  """
  @callback delete_api_key(key_id :: String.t()) :: :ok | {:error, term()}

  @doc "Resolve the configured client module (HTTP in prod, Mock in test)."
  @spec client() :: module()
  def client do
    Application.get_env(:driveway_os, :resend_client, Http)
  end

  @doc "Convenience wrapper that delegates to the configured client."
  @spec create_api_key(String.t()) ::
          {:ok, %{key_id: String.t(), api_key: String.t()}} | {:error, term()}
  def create_api_key(name), do: client().create_api_key(name)

  @doc "Convenience wrapper that delegates to the configured client."
  @spec delete_api_key(String.t()) :: :ok | {:error, term()}
  def delete_api_key(key_id), do: client().delete_api_key(key_id)
end
