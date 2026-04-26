defmodule DrivewayOS.Repo.Migrations.GrantGuestCheckoutToProPlus do
  @moduledoc """
  Adds `guest_checkout` to the features array of the seeded Pro
  and Enterprise plan rows. Idempotent — uses array_append guarded
  by a NOT-already-present check.

  Platform admins can toggle this on/off for any tier from
  `admin.<host>/plans` after the migration runs. Defaulting to
  Pro+ (off for Starter) so the friction-on-Starter pushes
  signups, while Pro tenants get the conversion-boost lever.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform_plans
    SET features = array_append(features, 'guest_checkout')
    WHERE tier IN ('pro', 'enterprise')
      AND NOT ('guest_checkout' = ANY(features))
    """)
  end

  def down do
    execute("""
    UPDATE platform_plans
    SET features = array_remove(features, 'guest_checkout')
    """)
  end
end
