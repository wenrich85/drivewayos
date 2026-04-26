defmodule DrivewayOS.Fleet do
  @moduledoc """
  The Fleet domain — customer-owned vehicles + addresses.

  Both resources are tenant-scoped and belong to a Customer. The
  same customer can register the same vehicle on two different
  tenants without colliding (each tenant gets its own Vehicle row).

  Booking flow uses these for the "pick from saved" pages of the
  wizard; an inline "add new" path also writes through this domain.
  """
  use Ash.Domain

  resources do
    resource DrivewayOS.Fleet.Vehicle
    resource DrivewayOS.Fleet.Address
  end
end
