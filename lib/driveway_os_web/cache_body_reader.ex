defmodule DrivewayOSWeb.CacheBodyReader do
  @moduledoc """
  Plug.Parsers body_reader that stashes the raw body on the conn
  before parsing it as JSON. Used by `StripeWebhookController` so
  signature verification has the original payload to HMAC against
  — the parsed JSON map can't be re-serialized identically.
  """
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, body)
    {:ok, body, conn}
  end
end
