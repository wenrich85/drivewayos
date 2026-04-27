defmodule DrivewayOSWeb.ErrorHTML do
  @moduledoc """
  Renders 404 / 500 error pages. We render branded HTML pages
  rather than the Phoenix default plain-text response so customers
  who hit a dead link see something that looks like the rest of
  the product.

  Tenant context (`conn.assigns[:current_tenant]`) is available
  when the LoadTenant plug ran before the error — typical for
  request-pipeline errors. For very early failures (before
  LoadTenant) we fall back to a generic DrivewayOS-branded page.
  """
  use DrivewayOSWeb, :html

  embed_templates "error_html/*"

  @doc """
  Best-effort tenant display name from assigns. Returns nil when
  the LoadTenant plug didn't run (early failure, /health, etc.) so
  the templates can fall back to generic copy.
  """
  def tenant_display_name(assigns) do
    case assigns[:current_tenant] do
      %{display_name: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end
end
