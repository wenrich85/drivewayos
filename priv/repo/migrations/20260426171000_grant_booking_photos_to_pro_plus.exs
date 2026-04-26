defmodule DrivewayOS.Repo.Migrations.GrantBookingPhotosToProPlus do
  @moduledoc """
  Adds `booking_photos` to the features array of the seeded Pro
  and Enterprise plan rows. Idempotent. Same shape as the
  guest_checkout grant — Starter stays bare-bones to push
  upgrades, Pro+ gets the conversion-quality lever.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform_plans
    SET features = array_append(features, 'booking_photos')
    WHERE tier IN ('pro', 'enterprise')
      AND NOT ('booking_photos' = ANY(features))
    """)
  end

  def down do
    execute("""
    UPDATE platform_plans
    SET features = array_remove(features, 'booking_photos')
    """)
  end
end
