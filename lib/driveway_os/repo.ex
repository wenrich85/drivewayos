defmodule DrivewayOS.Repo do
  use AshPostgres.Repo,
    otp_app: :driveway_os

  def installed_extensions do
    # Ash needs these Postgres extensions; gen_random_uuid() comes from
    # pgcrypto, citext powers case-insensitive email columns, and
    # `ash-functions` gives Ash's atomic-update / raise_ash_error
    # helpers.
    ["uuid-ossp", "pg_trgm", "citext", "ash-functions"]
  end

  def min_pg_version do
    # Match production target.
    %Version{major: 16, minor: 0, patch: 0}
  end
end
