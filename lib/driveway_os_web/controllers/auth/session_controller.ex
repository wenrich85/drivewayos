defmodule DrivewayOSWeb.Auth.SessionController do
  @moduledoc """
  Stores a customer JWT in the session after a successful LiveView
  sign-in. LiveViews can't write to session directly — they redirect
  here with a single-use token, this controller writes it, then
  redirects to the destination.

  The token has already been verified-and-minted by the SignInLive
  flow; this controller just persists it. Subsequent requests load
  the token via `LoadCustomer`, which re-verifies the signature
  (and the tenant claim) on every request.
  """
  use DrivewayOSWeb, :controller

  def store_token(conn, %{"token" => token} = params) do
    return_to = Map.get(params, "return_to", "/")

    conn
    |> put_session(:customer_token, token)
    |> redirect(to: return_to)
  end

  def sign_out(conn, _params) do
    conn
    |> delete_session(:customer_token)
    |> redirect(to: ~p"/")
  end
end
