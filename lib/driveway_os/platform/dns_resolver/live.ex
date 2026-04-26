defmodule DrivewayOS.Platform.DnsResolver.Live do
  @moduledoc """
  Production DNS lookups via Erlang's `:inet_res`. Returns lowercased
  string lists for both record types.

  Timeouts: `:inet_res` defaults to 2s per query with one retry, which
  is fine for an interactive "Verify now" click. The resolver is
  invoked synchronously from a LV handler so a slow lookup blocks
  the LV process — V2 punts the lookup into an Oban job if this
  becomes an issue.
  """
  @behaviour DrivewayOS.Platform.DnsResolver

  @impl true
  def lookup_cname(hostname) when is_binary(hostname) do
    case :inet_res.lookup(String.to_charlist(hostname), :in, :cname) do
      records when is_list(records) ->
        {:ok, records |> Enum.map(&to_string/1) |> Enum.map(&String.downcase/1)}

      _ ->
        {:error, :lookup_failed}
    end
  end

  @impl true
  def lookup_txt(hostname) when is_binary(hostname) do
    case :inet_res.lookup(String.to_charlist(hostname), :in, :txt) do
      records when is_list(records) ->
        # :inet_res returns each TXT record as a list of charlists
        # (one per quoted segment, since TXT records can be multi-string).
        # Concatenate segments + stringify.
        {:ok,
         records
         |> Enum.map(fn segs ->
           segs
           |> Enum.map(&to_string/1)
           |> Enum.join("")
         end)}

      _ ->
        {:error, :lookup_failed}
    end
  end
end
