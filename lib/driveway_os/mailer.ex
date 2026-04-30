defmodule DrivewayOS.Mailer do
  use Swoosh.Mailer, otp_app: :driveway_os

  @doc """
  Per-tenant Mailer config override. Phase 1 Task 6 adds this as
  a stub returning []; Task 15 expands it to actually branch on
  `tenant.postmark_api_key` and route through the Postmark adapter.
  """
  @spec for_tenant(any()) :: keyword()
  def for_tenant(_tenant), do: []
end
