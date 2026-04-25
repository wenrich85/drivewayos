defmodule DrivewayOS.Platform.PlatformToken do
  @moduledoc """
  AshAuthentication token storage for `PlatformUser`.

  Separate from any (eventual) `Accounts.Token` so platform-user
  sessions can't collide with customer sessions, and so the platform-
  user signing secret can rotate independently.
  """
  use Ash.Resource,
    otp_app: :driveway_os,
    domain: DrivewayOS.Platform,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshAuthentication.TokenResource]

  postgres do
    table "platform_tokens"
    repo DrivewayOS.Repo
  end

  actions do
    defaults [:read, :destroy]
  end
end
