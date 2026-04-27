defmodule DrivewayOSWeb.ErrorHTMLTest do
  use DrivewayOSWeb.ConnCase, async: true

  import Phoenix.Template, only: [render_to_string: 4]

  test "404.html renders branded copy with tenant display name" do
    body =
      render_to_string(
        DrivewayOSWeb.ErrorHTML,
        "404",
        "html",
        current_tenant: %{display_name: "Sparkle Wash"}
      )

    assert body =~ "This page doesn't exist"
    assert body =~ "Sparkle Wash"
    assert body =~ "404"
  end

  test "404.html falls back to generic copy without a tenant" do
    body = render_to_string(DrivewayOSWeb.ErrorHTML, "404", "html", [])

    assert body =~ "This page doesn't exist"
    assert body =~ "home"
    refute body =~ "Sparkle Wash"
  end

  test "500.html renders the friendly error copy" do
    body = render_to_string(DrivewayOSWeb.ErrorHTML, "500", "html", [])

    assert body =~ "Something went wrong"
    assert body =~ "500"
  end
end
