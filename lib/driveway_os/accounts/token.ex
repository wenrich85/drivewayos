defmodule DrivewayOS.Accounts.Token do
  @moduledoc """
  AshAuthentication token storage for `Customer`.

  This resource is intentionally NOT tenant-scoped — tenant isolation
  for sessions is enforced two ways:

    1. The JWT `subject` is `"customer:UUID"`, and the Customer
       resource IS tenant-scoped. Resolving the subject back to a
       customer requires the right tenant in context.
    2. (Slice 2D) The JWT carries a `tenant_id` claim; the loader
       plug rejects the token if its tenant claim doesn't match the
       current subdomain's tenant.

  A stolen JWT presented on the wrong subdomain therefore fails at
  step 1 (Customer not found in that tenant) and step 2 (claim
  mismatch). Making the token table itself tenant-scoped would add
  no extra safety while complicating cleanup jobs.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "tokens"
    repo DrivewayOS.Repo
  end

  actions do
    defaults [:read, :destroy]
  end
end
