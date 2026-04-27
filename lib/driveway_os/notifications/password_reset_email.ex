defmodule DrivewayOS.Notifications.PasswordResetEmail do
  @moduledoc """
  Password-reset link email — sent when a customer hits
  `Auth.ForgotPasswordLive` and AshAuthentication's resettable
  add-on mints a single-use reset token.

  Token expires fast (default 1 day in AshAuth's resettable
  config) since the lookup → email → click loop is short. The
  link points at `/reset-password/:token` on the tenant's host.
  """
  import Swoosh.Email

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Branding
  alias DrivewayOS.Platform.Tenant

  @spec reset_link(Tenant.t(), Customer.t(), String.t()) :: Swoosh.Email.t()
  def reset_link(%Tenant{} = tenant, %Customer{} = customer, link_url)
      when is_binary(link_url) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Reset your password for #{Branding.display_name(tenant)}")
    |> text_body("""
    Hi #{customer.name},

    Someone (hopefully you) asked to reset your password at
    #{Branding.display_name(tenant)}. Click the link below to
    pick a new one:

      #{link_url}

    The link expires soon. If you didn't ask for a reset, just
    ignore this email — your password won't change until the
    link is clicked.

    -- #{Branding.display_name(tenant)}
    """)
  end
end
