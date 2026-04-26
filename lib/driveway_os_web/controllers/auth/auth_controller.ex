defmodule DrivewayOSWeb.Auth.AuthController do
  @moduledoc """
  Single controller that handles every AshAuthentication-driven OAuth
  callback for `Customer`. Wired via `auth_routes/3` in the router.

  The flow on a successful sign-in (Google/Facebook/Apple):

      browser → /auth/customer/{provider}        (strategy router redirects to provider)
      browser → /auth/customer/{provider}/callback   (provider redirects back)
        ↓
      AshAuthentication does the code exchange + finds-or-creates the
      Customer (tenant-scoped via current_tenant in conn.assigns)
        ↓
      success/4 is called — we mint a JWT and persist it to the
      session via the existing customer_token key, then redirect.

  Failures land on `failure/3` and bounce back to /sign-in with an
  inline error.
  """
  use DrivewayOSWeb, :controller
  use AshAuthentication.Phoenix.Controller

  def success(conn, _activity, user, _token) do
    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)

    conn
    |> put_session(:customer_token, token)
    |> redirect(to: ~p"/")
  end

  def failure(conn, _activity, _reason) do
    conn
    |> put_flash(:error, "Sign-in failed. Please try a different method.")
    |> redirect(to: ~p"/sign-in")
  end

  def sign_out(conn, _params) do
    conn
    |> delete_session(:customer_token)
    |> redirect(to: ~p"/")
  end
end
