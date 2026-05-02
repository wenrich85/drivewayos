defmodule DrivewayOS.Repo.Migrations.AddObanJobsTable do
  @moduledoc """
  Phase 3 Task 10: install Oban's required `oban_jobs` table (plus
  associated types/indexes). Defers the schema details to Oban's own
  migration helper so future Oban upgrades stay drop-in.
  """
  use Ecto.Migration

  def up do
    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down()
  end
end
