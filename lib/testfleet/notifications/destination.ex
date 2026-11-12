defmodule TestFleet.Notifications.Destination do
  @moduledoc """
  Decides whether a webhook URL may be requested.

  A webhook URL is chosen by an organization's admin, and TestFleet sends the
  request from inside its own network: next to the Docker socket proxy, the
  database, and whatever else the host can reach. Where admins are tenants
  (`:multi` mode), a URL that points there would let one organization reach what
  is not theirs, so hosts that resolve to a loopback, private, link-local, or
  otherwise internal address are refused.

  A self-hosted installation (`:single` mode) usually has its chat server or
  webhook receiver on the internal network, so everything is allowed there.
  `WEBHOOK_ALLOW_PRIVATE_HOSTS` (`config :testfleet, TestFleet.Notifications,
  allow_private_hosts: boolean`) overrides either default.

  The host is resolved here and again by the HTTP client: a DNS server that
  answers differently the second time is not covered.
  """

  import Bitwise

  alias TestFleet.Organizations

  @doc "Whether hosts on internal networks may be requested."
  def allow_private_hosts? do
    case Application.get_env(:testfleet, TestFleet.Notifications, [])[:allow_private_hosts] do
      nil -> not Organizations.multi?()
      allow? -> allow?
    end
  end

  @doc """
  `:ok`, or `{:error, reason}` when the URL's host is, or resolves to, an internal
  address and those are not allowed. `reason` never contains the URL.
  """
  @spec check(String.t()) :: :ok | {:error, String.t()}
  def check(url) do
    if allow_private_hosts?(), do: :ok, else: check_public(url)
  end

  defp check_public(url) do
    with %URI{host: host} when host not in [nil, ""] <- URI.parse(url),
         [_ | _] = addresses <- resolve(host) do
      if Enum.any?(addresses, &internal?/1),
        do: {:error, "the host is on an internal network, which is not allowed"},
        else: :ok
    else
      _ -> {:error, "the host could not be resolved"}
    end
  end

  defp resolve(host) do
    host = String.to_charlist(host)

    case :inet.parse_address(host) do
      {:ok, address} ->
        [address]

      {:error, _} ->
        for family <- [:inet, :inet6],
            {:ok, addresses} <- [:inet.getaddrs(host, family)],
            address <- addresses,
            do: address
    end
  end

  @doc "Whether an address (an `:inet` tuple) is loopback, private, link-local, or reserved."
  def internal?({a, b, _c, _d}) do
    a in [0, 10, 127] or
      a >= 224 or
      (a == 100 and b in 64..127) or
      (a == 169 and b == 254) or
      (a == 172 and b in 16..31) or
      (a == 192 and b == 168) or
      (a == 198 and b in 18..19)
  end

  # IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::/96): judged by the IPv4 address.
  def internal?({0, 0, 0, 0, 0, 0xFFFF, high, low}), do: internal?(ipv4(high, low))
  def internal?({0x64, 0xFF9B, 0, 0, 0, 0, high, low}), do: internal?(ipv4(high, low))

  def internal?({a, _b, _c, _d, _e, _f, _g, _h} = address) do
    # Unspecified and loopback, unique local (fc00::/7), link-local (fe80::/10),
    # and multicast (ff00::/8)
    address in [{0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 0, 0, 0, 1}] or
      (a &&& 0xFE00) == 0xFC00 or
      (a &&& 0xFFC0) == 0xFE80 or
      (a &&& 0xFF00) == 0xFF00
  end

  defp ipv4(high, low), do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}
end
