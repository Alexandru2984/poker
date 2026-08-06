defmodule MicuPokerWeb.Plugs.RemoteIp do
  @moduledoc """
  Resolves the real client IP when the app runs behind nginx and Cloudflare.

  The release binds to `127.0.0.1`, so `conn.remote_ip` is always the local
  nginx socket. Forwarded headers are only honoured when the immediate peer is
  a configured trusted proxy, otherwise a client could spoof its own address by
  sending `x-forwarded-for` directly.

  Resolution order once the peer is trusted:

    1. `cf-connecting-ip`, when Cloudflare is trusted (`TRUST_CLOUDFLARE=true`).
    2. The right-most `x-forwarded-for` entry that is not itself a trusted proxy.

  The resolved address replaces `conn.remote_ip` and is also exposed as the
  `:client_ip` assign for logging and rate limiting.
  """

  @behaviour Plug

  import Bitwise
  import Plug.Conn

  @default_trusted_proxies ["127.0.0.1/32", "::1/128"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    ip = resolve(conn.remote_ip, conn.req_headers)

    conn
    |> Map.put(:remote_ip, ip)
    |> assign(:client_ip, format(ip))
  end

  @doc """
  Resolves the client address from a peer address and its request headers.

  Exposed separately from `call/2` so socket transports, which never build a
  `Plug.Conn`, can reuse the same trust rules.
  """
  def resolve(peer_ip, headers) when is_list(headers) do
    if trusted_proxy?(peer_ip) do
      cloudflare_ip(headers) || forwarded_ip(headers) || peer_ip
    else
      peer_ip
    end
  end

  def resolve(peer_ip, _headers), do: peer_ip

  @doc """
  Resolves the client address string from Phoenix socket `connect_info`.

  Requires the socket to declare `connect_info: [:peer_data, :x_headers, ...]`.
  """
  def from_connect_info(%{peer_data: %{address: address}} = connect_info) do
    connect_info
    |> Map.get(:x_headers, [])
    |> then(&resolve(address, &1))
    |> format()
  end

  def from_connect_info(_connect_info), do: "unknown"

  @doc """
  Renders an IP tuple as a printable string, falling back to `"unknown"`.
  """
  def format(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _reason} -> "unknown"
      charlist -> List.to_string(charlist)
    end
  end

  def format(_ip), do: "unknown"

  defp cloudflare_ip(headers) do
    if trust_cloudflare?() do
      headers |> header_values("cf-connecting-ip") |> List.first() |> parse_ip()
    end
  end

  # Walk right to left and stop at the first address that is not one of our own
  # proxies. Anything further left was supplied by the client and is untrusted.
  defp forwarded_ip(headers) do
    headers
    |> header_values("x-forwarded-for")
    |> Enum.join(",")
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> parse_ip()))
    |> Enum.reject(&is_nil/1)
    |> Enum.reverse()
    |> Enum.find(&(not trusted_proxy?(&1)))
    |> case do
      nil -> headers |> header_values("x-real-ip") |> List.first() |> parse_ip()
      ip -> ip
    end
  end

  defp header_values(headers, name) do
    for {key, value} <- headers, String.downcase(key) == name, do: value
  end

  defp parse_ip(nil), do: nil
  defp parse_ip(""), do: nil

  defp parse_ip(value) when is_binary(value) do
    # Some proxies append a port, and IPv6 entries may be bracketed.
    value
    |> String.trim()
    |> String.trim_leading("[")
    |> String.split("]")
    |> List.first()
    |> strip_ipv4_port()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _reason} -> nil
    end
  end

  defp parse_ip(_value), do: nil

  defp strip_ipv4_port(value) do
    case String.split(value, ":") do
      [ipv4, _port] -> ipv4
      _other -> value
    end
  end

  defp trusted_proxy?(ip) when is_tuple(ip) do
    Enum.any?(trusted_proxies(), &in_cidr?(ip, &1))
  end

  defp trusted_proxy?(_ip), do: false

  defp trusted_proxies do
    case :persistent_term.get({__MODULE__, :trusted_proxies}, nil) do
      nil ->
        parsed = load_trusted_proxies()
        :persistent_term.put({__MODULE__, :trusted_proxies}, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  defp load_trusted_proxies do
    configured =
      Application.get_env(:micu_poker, :trusted_proxies) ||
        split_env("TRUSTED_PROXIES") ||
        @default_trusted_proxies

    configured
    |> Enum.map(&parse_cidr/1)
    |> Enum.reject(&is_nil/1)
  end

  defp trust_cloudflare? do
    case :persistent_term.get({__MODULE__, :trust_cloudflare}, nil) do
      nil ->
        value =
          case Application.get_env(:micu_poker, :trust_cloudflare) do
            nil -> System.get_env("TRUST_CLOUDFLARE") in ~w(true 1 yes)
            configured -> !!configured
          end

        :persistent_term.put({__MODULE__, :trust_cloudflare}, value)
        value

      value ->
        value
    end
  end

  defp split_env(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> case do
          [] -> nil
          entries -> entries
        end
    end
  end

  @doc """
  Parses a `"1.2.3.4/24"` style CIDR into `{address, prefix_length}`.
  """
  def parse_cidr(value) when is_binary(value) do
    {address, prefix} =
      case String.split(value, "/", parts: 2) do
        [address] -> {address, nil}
        [address, prefix] -> {address, parse_prefix(prefix)}
      end

    case :inet.parse_address(String.to_charlist(String.trim(address))) do
      {:ok, ip} ->
        bits = address_bits(ip)
        prefix = if is_integer(prefix) and prefix in 0..bits, do: prefix, else: bits
        {ip, prefix}

      {:error, _reason} ->
        nil
    end
  end

  def parse_cidr(_value), do: nil

  defp parse_prefix(prefix) do
    case Integer.parse(String.trim(prefix)) do
      {value, ""} -> value
      _other -> nil
    end
  end

  @doc """
  Returns true when `ip` falls inside the `{address, prefix_length}` range.
  """
  def in_cidr?(ip, {network, prefix}) when tuple_size(ip) == tuple_size(network) do
    bits = address_bits(ip)
    mask = if prefix == 0, do: 0, else: ((1 <<< prefix) - 1) <<< (bits - prefix)

    (to_integer(ip) &&& mask) == (to_integer(network) &&& mask)
  end

  def in_cidr?(_ip, _cidr), do: false

  defp address_bits(ip) when tuple_size(ip) == 4, do: 32
  defp address_bits(ip) when tuple_size(ip) == 8, do: 128

  defp to_integer(ip) when tuple_size(ip) == 4 do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn octet, acc -> acc <<< 8 ||| octet end)
  end

  defp to_integer(ip) when tuple_size(ip) == 8 do
    ip |> Tuple.to_list() |> Enum.reduce(0, fn group, acc -> acc <<< 16 ||| group end)
  end
end
