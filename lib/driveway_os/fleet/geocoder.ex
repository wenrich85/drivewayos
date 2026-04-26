defmodule DrivewayOS.Fleet.Geocoder do
  @moduledoc """
  Behaviour for resolving a US zip code (or full address) to
  `{lat, lon}`. Used by `Address` create/update changes to populate
  the geo columns.

  V1 ships with `Geocoder.Stub` (no-op, returns nil/nil) wired by
  default. Production deployments swap in a real provider via
  `Application.put_env(:driveway_os, :geocoder, Module)` — see
  Phase B route-optimizer work.

  Each impl must return `{:ok, %{lat: float | nil, lon: float | nil}}`
  even when it can't geocode — the row still saves, lat/lon stay
  nil, and the route optimizer just skips it.
  """

  @callback lookup(zip_or_query :: String.t()) ::
              {:ok, %{lat: float() | nil, lon: float() | nil}} | {:error, term()}

  def impl, do: Application.get_env(:driveway_os, :geocoder, DrivewayOS.Fleet.Geocoder.Stub)

  def lookup(query) when is_binary(query), do: impl().lookup(query)
end
