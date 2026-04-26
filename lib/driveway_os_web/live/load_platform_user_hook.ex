defmodule DrivewayOSWeb.LoadPlatformUserHook do
  @moduledoc """
  on_mount hook that mirrors `LoadPlatformUser` plug into LiveView
  socket assigns. Reads `:platform_token` from the session map and
  resolves it.
  """
  import Phoenix.Component, only: [assign: 3]

  alias AshAuthentication.Jwt
  alias DrivewayOS.Platform.PlatformUser

  def on_mount(:default, _params, session, socket) do
    user =
      case session["platform_token"] do
        token when is_binary(token) ->
          with {:ok, %{"sub" => sub}, _resource} <- Jwt.verify(token, PlatformUser),
               {:ok, user} <-
                 AshAuthentication.subject_to_user(sub, PlatformUser, authorize?: false) do
            user
          else
            _ -> nil
          end

        _ ->
          nil
      end

    {:cont, assign(socket, :current_platform_user, user)}
  end
end
