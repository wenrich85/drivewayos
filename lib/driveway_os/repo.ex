defmodule DrivewayOS.Repo do
  use AshPostgres.Repo,
    otp_app: :driveway_os

  def installed_extensions do
    # Ash needs these Postgres extensions; gen_random_uuid() comes from
    # pgcrypto and citext powers case-insensitive email columns.
    ["uuid-ossp", "pg_trgm", "citext"]
  end

  def min_pg_version do
    # Match production target.
    %Version{major: 16, minor: 0, patch: 0}
  end
end
