defmodule DrivewayOSWeb.AlwaysOkDnsResolver do
  @moduledoc """
  Test-only DNS resolver that always reports "yes, your CNAME
  points at our edge". Used by the Wallaby custom-domain feature
  test, where Mox can't be used because the endpoint runs in a
  separate process from the test.

  Don't use this anywhere outside test/.
  """
  @behaviour DrivewayOS.Platform.DnsResolver

  @impl true
  def lookup_cname(_hostname) do
    target = "edge." <> Application.fetch_env!(:driveway_os, :platform_host)
    {:ok, [target]}
  end

  @impl true
  def lookup_txt(_hostname), do: {:ok, []}
end
