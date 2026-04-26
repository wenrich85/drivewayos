defmodule DrivewayOS.Branding do
  @moduledoc """
  Single source of truth for tenant-driven branding fields used in
  user-visible surfaces (emails, PDF receipts, external links).

  When a tenant changes their display name / support email / primary
  color, every surface picks it up automatically. The reverse is
  also true: if you bypass this helper and hardcode "DrivewayOS"
  somewhere, you've created a multi-tenancy leak.

  Defaults are intentional fallbacks — used during development
  before a tenant fills in their branding fields.
  """
  alias DrivewayOS.Platform.Tenant

  @default_display_name "DrivewayOS"
  @default_primary_color_hex "#0d9488"
  @default_from_email_local "noreply"

  @spec display_name(Tenant.t() | nil) :: String.t()
  def display_name(nil), do: @default_display_name
  def display_name(%Tenant{display_name: nil}), do: @default_display_name
  def display_name(%Tenant{display_name: name}), do: name

  @spec from_email(Tenant.t() | nil) :: String.t()
  def from_email(nil), do: platform_from_email()
  def from_email(%Tenant{support_email: nil}), do: platform_from_email()
  def from_email(%Tenant{support_email: email}), do: email

  @spec from_address(Tenant.t() | nil) :: {String.t(), String.t()}
  def from_address(tenant), do: {display_name(tenant), from_email(tenant)}

  @spec primary_color_hex(Tenant.t() | nil) :: String.t()
  def primary_color_hex(nil), do: @default_primary_color_hex
  def primary_color_hex(%Tenant{primary_color_hex: nil}), do: @default_primary_color_hex
  def primary_color_hex(%Tenant{primary_color_hex: hex}), do: hex

  # --- Private helpers ---

  defp platform_from_email do
    host = Application.get_env(:driveway_os, :platform_host, "drivewayos.com")
    "#{@default_from_email_local}@#{host}"
  end
end
