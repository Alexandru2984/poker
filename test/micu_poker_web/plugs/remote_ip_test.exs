defmodule MicuPokerWeb.Plugs.RemoteIpTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias MicuPokerWeb.Plugs.RemoteIp

  @loopback {127, 0, 0, 1}
  @public {203, 0, 113, 7}

  setup do
    # The plug caches its trust configuration in :persistent_term, so each test
    # sets what it needs and the cache is dropped afterwards.
    on_exit(&reset_cache/0)
    reset_cache()
    :ok
  end

  defp reset_cache do
    :persistent_term.erase({RemoteIp, :trusted_proxies})
    :persistent_term.erase({RemoteIp, :trust_cloudflare})
    Application.delete_env(:micu_poker, :trusted_proxies)
    Application.delete_env(:micu_poker, :trust_cloudflare)
  end

  defp run(headers, peer \\ @loopback) do
    :get
    |> conn("/")
    |> Map.put(:remote_ip, peer)
    |> then(fn conn ->
      Enum.reduce(headers, conn, fn {key, value}, acc -> put_req_header(acc, key, value) end)
    end)
    |> RemoteIp.call([])
  end

  test "keeps the peer address when no forwarded headers are present" do
    assert run([]).remote_ip == @loopback
  end

  test "uses x-forwarded-for when the peer is a trusted proxy" do
    conn = run([{"x-forwarded-for", "203.0.113.7"}])

    assert conn.remote_ip == @public
    assert conn.assigns.client_ip == "203.0.113.7"
  end

  test "ignores forwarded headers from an untrusted peer" do
    conn = run([{"x-forwarded-for", "203.0.113.7"}], {198, 51, 100, 2})

    assert conn.remote_ip == {198, 51, 100, 2}
  end

  test "takes the right-most untrusted entry from a forwarded chain" do
    Application.put_env(:micu_poker, :trusted_proxies, ["127.0.0.1/32", "10.0.0.0/8"])

    conn = run([{"x-forwarded-for", "203.0.113.7, 10.1.2.3, 10.4.5.6"}])

    assert conn.remote_ip == @public
  end

  test "a client-supplied forwarded chain cannot spoof past our proxies" do
    Application.put_env(:micu_poker, :trusted_proxies, ["127.0.0.1/32"])

    # The attacker sends "1.2.3.4"; nginx appends the address it actually saw.
    conn = run([{"x-forwarded-for", "1.2.3.4, 203.0.113.7"}])

    assert conn.remote_ip == @public
  end

  test "prefers cf-connecting-ip when Cloudflare is trusted" do
    Application.put_env(:micu_poker, :trust_cloudflare, true)

    conn =
      run([
        {"cf-connecting-ip", "203.0.113.7"},
        {"x-forwarded-for", "198.51.100.9"}
      ])

    assert conn.remote_ip == @public
  end

  test "ignores cf-connecting-ip when Cloudflare is not trusted" do
    Application.put_env(:micu_poker, :trust_cloudflare, false)

    conn =
      run([
        {"cf-connecting-ip", "203.0.113.7"},
        {"x-forwarded-for", "198.51.100.9"}
      ])

    assert conn.remote_ip == {198, 51, 100, 9}
  end

  test "falls back to x-real-ip when the forwarded chain is only proxies" do
    Application.put_env(:micu_poker, :trusted_proxies, ["127.0.0.1/32"])

    conn = run([{"x-forwarded-for", "127.0.0.1"}, {"x-real-ip", "203.0.113.7"}])

    assert conn.remote_ip == @public
  end

  test "strips an appended port from an IPv4 entry" do
    assert run([{"x-forwarded-for", "203.0.113.7:44321"}]).remote_ip == @public
  end

  test "parses bracketed IPv6 entries" do
    Application.put_env(:micu_poker, :trusted_proxies, ["127.0.0.1/32"])

    conn = run([{"x-forwarded-for", "[2001:db8::1]"}])

    assert conn.remote_ip == {8193, 3512, 0, 0, 0, 0, 0, 1}
  end

  test "ignores malformed entries instead of crashing" do
    assert run([{"x-forwarded-for", "not-an-ip, 203.0.113.7"}]).remote_ip == @public
    assert run([{"x-forwarded-for", "unknown"}]).remote_ip == @loopback
  end

  describe "in_cidr?/2" do
    test "matches inside and outside an IPv4 range" do
      cidr = RemoteIp.parse_cidr("10.0.0.0/8")

      assert RemoteIp.in_cidr?({10, 255, 3, 1}, cidr)
      refute RemoteIp.in_cidr?({11, 0, 0, 1}, cidr)
    end

    test "a bare address is treated as a single host" do
      cidr = RemoteIp.parse_cidr("127.0.0.1")

      assert RemoteIp.in_cidr?({127, 0, 0, 1}, cidr)
      refute RemoteIp.in_cidr?({127, 0, 0, 2}, cidr)
    end

    test "does not match across address families" do
      refute RemoteIp.in_cidr?({127, 0, 0, 1}, RemoteIp.parse_cidr("::1/128"))
    end

    test "a /0 range matches everything in its family" do
      assert RemoteIp.in_cidr?({8, 8, 8, 8}, RemoteIp.parse_cidr("0.0.0.0/0"))
    end
  end
end
