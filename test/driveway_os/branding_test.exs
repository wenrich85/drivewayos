defmodule DrivewayOS.BrandingTest do
  @moduledoc """
  Branding helper — single source of truth for "what does this
  tenant look/sound like in user-visible surfaces".

  Used by every email template, every PDF receipt, every external
  link. Centralized so the day a tenant changes their display name
  / support email / primary color, every surface picks it up.
  """
  use ExUnit.Case, async: true

  alias DrivewayOS.Branding
  alias DrivewayOS.Platform.Tenant

  describe "display_name/1" do
    test "returns the tenant's display_name" do
      assert Branding.display_name(%Tenant{display_name: "Acme Wash Co"}) == "Acme Wash Co"
    end

    test "falls back to 'DrivewayOS' for nil" do
      assert Branding.display_name(nil) == "DrivewayOS"
    end
  end

  describe "from_email/1" do
    test "uses tenant.support_email when present" do
      tenant = %Tenant{
        display_name: "Acme",
        support_email: "hello@acmewash.com"
      }

      assert Branding.from_email(tenant) == "hello@acmewash.com"
    end

    test "falls back to platform default when nil" do
      tenant = %Tenant{display_name: "Acme", support_email: nil}
      # Platform default in test env
      assert Branding.from_email(tenant) =~ "@"
    end
  end

  describe "from_address/1" do
    test "returns a Swoosh-style {name, email} tuple" do
      tenant = %Tenant{display_name: "Acme Wash", support_email: "noreply@acme.com"}
      assert Branding.from_address(tenant) == {"Acme Wash", "noreply@acme.com"}
    end
  end

  describe "primary_color_hex/1" do
    test "returns the tenant's color or a default" do
      assert Branding.primary_color_hex(%Tenant{primary_color_hex: "#1d4ed8"}) == "#1d4ed8"
      assert Branding.primary_color_hex(%Tenant{primary_color_hex: nil}) == "#0d9488"
    end
  end
end
