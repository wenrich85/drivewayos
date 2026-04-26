defmodule DrivewayOS.Notifications.EmailVerification do
  @moduledoc """
  Email verification token + email helpers.

  We mint a regular AshAuthentication customer JWT with an extra
  `verify_email` claim so it can't be presented as a sign-in token.
  The token's `tenant` claim is set automatically by the multi-tenancy
  block on Customer, which means a verify token from tenant A
  presented on tenant B's subdomain fails verification before we
  ever look up a row.
  """
  import Swoosh.Email

  alias DrivewayOS.Accounts.Customer
  alias DrivewayOS.Branding
  alias DrivewayOS.Platform.Tenant

  @ttl_minutes 60 * 24

  @doc """
  Mint a single-use email-verification token for `customer`.
  """
  @spec mint_token(Customer.t()) :: String.t()
  def mint_token(%Customer{} = customer) do
    {:ok, token, _claims} =
      AshAuthentication.Jwt.token_for_user(
        customer,
        %{"verify_email" => true},
        token_lifetime: {@ttl_minutes, :minutes}
      )

    token
  end

  @doc """
  Verify a token. Returns `{:ok, customer}` on success or `:error`
  for any failure (bad signature, wrong tenant, expired, missing
  verify_email claim).
  """
  @spec verify_token(String.t(), Tenant.t()) :: {:ok, Customer.t()} | :error
  def verify_token(token, %Tenant{} = tenant) when is_binary(token) do
    with {:ok, %{"sub" => subject, "verify_email" => true}, _resource} <-
           AshAuthentication.Jwt.verify(token, :driveway_os, tenant: tenant.id),
         {:ok, customer} <-
           AshAuthentication.subject_to_user(subject, Customer, tenant: tenant.id) do
      {:ok, customer}
    else
      _ -> :error
    end
  end

  @spec build_email(Tenant.t(), Customer.t(), String.t()) :: Swoosh.Email.t()
  def build_email(%Tenant{} = tenant, %Customer{} = customer, link_url) do
    new()
    |> to({customer.name, to_string(customer.email)})
    |> from(Branding.from_address(tenant))
    |> subject("Verify your email for #{Branding.display_name(tenant)}")
    |> text_body("""
    Hi #{customer.name},

    Click below to verify your email address with #{Branding.display_name(tenant)}:

      #{link_url}

    The link expires in #{div(@ttl_minutes, 60)} hours. If you
    didn't sign up, ignore this email.

    -- #{Branding.display_name(tenant)}
    """)
  end
end
