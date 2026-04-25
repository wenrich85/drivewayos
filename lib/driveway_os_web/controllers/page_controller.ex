defmodule DrivewayOSWeb.PageController do
  use DrivewayOSWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
