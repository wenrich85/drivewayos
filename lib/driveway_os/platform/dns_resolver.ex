defmodule DrivewayOS.Platform.DnsResolver do
  @moduledoc """
  Behaviour wrapping the DNS lookups we need for custom-domain
  verification. Real impl in `DnsResolver.Live` (Erlang :inet_res);
  tests swap in a Mox-backed mock so they never hit the network.

  Returns `{:ok, [...]}` with all matching records, or `{:error, term}`.
  An empty list (NXDOMAIN-equivalent) is a successful `{:ok, []}`.
  """

  @callback lookup_cname(hostname :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
  @callback lookup_txt(hostname :: String.t()) :: {:ok, [String.t()]} | {:error, term()}

  @doc """
  Returns the configured implementation. Real impl in dev/prod, mock
  in test.
  """
  def impl,
    do:
      Application.get_env(
        :driveway_os,
        :dns_resolver,
        DrivewayOS.Platform.DnsResolver.Live
      )

  def lookup_cname(hostname), do: impl().lookup_cname(hostname)
  def lookup_txt(hostname), do: impl().lookup_txt(hostname)
end
