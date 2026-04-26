defmodule DrivewayOSWeb.Platform.SessionController do
  @moduledoc """
  Persists a PlatformUser JWT to the session after a successful
  Platform.SignInLive submit. Mirrors Auth.SessionController but
  uses the `:platform_token` session key (separate from
  `:customer_token` so the two populations never cross).
  """
  use DrivewayOSWeb, :controller

  def store_token(conn, %{"token" => token} = params) do
    return_to = Map.get(params, "return_to", "/tenants")

    conn
    |> put_session(:platform_token, token)
    |> redirect(to: return_to)
  end

  def sign_out(conn, _params) do
    conn
    |> delete_session(:platform_token)
    |> redirect(to: ~p"/")
  end
end
