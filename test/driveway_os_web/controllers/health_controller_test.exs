defmodule DrivewayOSWeb.HealthControllerTest do
  use DrivewayOSWeb.ConnCase, async: true

  test "GET /health returns 200 + ok JSON when DB is up", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "lvh.me")
      |> get("/health")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") |> List.first() =~ "application/json"

    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "ok"
    assert body["db"] == "ok"
  end
end
