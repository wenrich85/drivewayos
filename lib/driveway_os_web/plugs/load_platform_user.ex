defmodule DrivewayOSWeb.Plugs.LoadPlatformUser do
  @moduledoc """
  Reads `:platform_token` from the session and resolves it to a
  PlatformUser. Assigns `conn.assigns[:current_platform_user]` —
  nil if no token, expired, or invalid.

  Runs only when the LoadTenant plug has already classified the
  context as `:platform_admin`. On any other host it's a no-op.

  Separate from LoadCustomer because PlatformUser tokens are signed
  with a different secret (`:platform_token_signing_secret`) so a
  stolen customer JWT can never escalate into platform-admin scope.
  """
  import Plug.Conn

  alias AshAuthentication.Jwt
  alias DrivewayOS.Platform.PlatformUser

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{tenant_context: :platform_admin}} = conn, _opts) do
    user =
      case get_session(conn, :platform_token) do
        token when is_binary(token) ->
          with {:ok, %{"sub" => sub}, _} <- Jwt.verify(token, PlatformUser),
               {:ok, user} <-
                 AshAuthentication.subject_to_user(sub, PlatformUser, authorize?: false) do
            user
          else
            _ -> nil
          end

        _ ->
          nil
      end

    assign(conn, :current_platform_user, user)
  end

  def call(conn, _opts), do: assign(conn, :current_platform_user, nil)
end
