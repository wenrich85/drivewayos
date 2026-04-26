defmodule DrivewayOS.Fleet.Geocoder.Stub do
  @moduledoc """
  Default geocoder — returns nil/nil for everything. Lets dev / test
  / freshly-deployed prod keep working without a configured
  geocoding provider. The Address resource saves cleanly; lat/lon
  remain nil until a real provider is wired up (Phase B).
  """
  @behaviour DrivewayOS.Fleet.Geocoder

  @impl true
  def lookup(_query), do: {:ok, %{lat: nil, lon: nil}}
end
