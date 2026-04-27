defmodule DrivewayOS.Repo.Migrations.GrantSmsNotificationsToProPlus do
  @moduledoc """
  Adds `sms_notifications` to Pro + Enterprise. Same shape as the
  prior Pro+ feature grants. Starter remains email-only — SMS is
  the operational lever (anti-no-show + day-of-coordination)
  worth upgrading for.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE platform_plans
    SET features = array_append(features, 'sms_notifications')
    WHERE tier IN ('pro', 'enterprise')
      AND NOT ('sms_notifications' = ANY(features))
    """)
  end

  def down do
    execute("""
    UPDATE platform_plans
    SET features = array_remove(features, 'sms_notifications')
    """)
  end
end
