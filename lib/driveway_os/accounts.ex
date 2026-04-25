defmodule DrivewayOS.Accounts do
  @moduledoc """
  The Accounts domain — tenant-scoped customer authentication +
  profile.

  Every resource in this domain has `multitenancy do strategy
  :attribute; attribute :tenant_id end`, so every Ash query in this
  domain must pass `tenant:` or it raises.

  V1 Slice 2A: password auth only. OAuth providers (Google, Apple,
  Facebook) land in Slice 2C as additional `strategies do … end`
  entries on `Customer`.
  """
  use Ash.Domain

  resources do
    resource DrivewayOS.Accounts.Customer
    resource DrivewayOS.Accounts.Token
  end
end
