defmodule DrivewayOSWeb.HealthController do
  @moduledoc """
  GET /health — load-balancer probe. Verifies the app is up AND
  the DB is reachable. Returns 200 + JSON on success, 503 + JSON
  on a degraded dependency.

  Exempt from force_ssl + tenant resolution + auth so deploys can
  point at it from the bare host (no DNS needed for the LB
  config).
  """
  use DrivewayOSWeb, :controller

  def index(conn, _params) do
    db_status =
      try do
        Ecto.Adapters.SQL.query!(DrivewayOS.Repo, "SELECT 1", [])
        :ok
      rescue
        _ -> :error
      end

    case db_status do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode!(%{status: "ok", db: "ok"}))

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{status: "degraded", db: "error"}))
    end
  end
end
