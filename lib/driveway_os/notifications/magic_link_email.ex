defmodule DrivewayOS.Notifications.MagicLinkEmail do
  @moduledoc """
  Sign-in link email — sent by `MagicLinkLive` when a customer
  asks to be emailed a one-click sign-in. The link points at
  `/auth/customer/magic-link?token=...` on the tenant's host.

  Token is a regular AshAuthentication customer JWT, just
  short-lived (default 5 min when minted via SignInLive's helper).
  """
  import Swoosh.Email

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Branding
  alias DrivewayOS.Platform.Tenant

  @spec sign_in(Tenant.t(), Customer.t(), String.t()) :: Swoosh.Email.t()
  def sign_in(%Tenant{} = tenant, %Customer{} = customer, link_url) when is_binary(link_url) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Your sign-in link for #{Branding.display_name(tenant)}")
    |> text_body("""
    Hi #{customer.name},

    Click below to sign in to #{Branding.display_name(tenant)}:

      #{link_url}

    The link expires in 15 minutes. If you didn't ask to sign in,
    just ignore this email.

    -- #{Branding.display_name(tenant)}
    """)
  end
end
