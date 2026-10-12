defmodule MicuPokerWeb.Plugs.SecurityHeadersTest do
  use MicuPokerWeb.ConnCase, async: false

  alias MicuPokerWeb.Plugs.SecurityHeaders

  setup do
    on_exit(fn ->
      :persistent_term.erase({SecurityHeaders, :csp})
      Application.delete_env(:micu_poker, :hsts_enabled)
    end)

    :ok
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  test "browser responses carry a content security policy", %{conn: conn} do
    conn = get(conn, ~p"/")
    csp = header(conn, "content-security-policy")

    assert csp =~ "default-src 'self'"
    assert csp =~ "object-src 'none'"
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "form-action 'self'"
    assert csp =~ "base-uri 'self'"
  end

  test "scripts are restricted to same-origin with no inline allowance", %{conn: conn} do
    csp = conn |> get(~p"/") |> header("content-security-policy")

    assert csp =~ "script-src 'self'"
    refute csp =~ "script-src 'self' 'unsafe-inline'"
    refute csp =~ "unsafe-eval"
  end

  test "websocket origins are allowed so LiveView can connect", %{conn: conn} do
    csp = conn |> get(~p"/") |> header("content-security-policy")
    host = MicuPokerWeb.Endpoint.host()

    assert csp =~ "connect-src"
    assert csp =~ "wss://#{host}"
  end

  test "cross-origin isolation headers are set", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert header(conn, "cross-origin-opener-policy") == "same-origin"
    assert header(conn, "cross-origin-resource-policy") == "same-origin"
    assert header(conn, "x-permitted-cross-domain-policies") == "none"
    assert header(conn, "x-frame-options") == "DENY"
    assert header(conn, "x-content-type-options") == "nosniff"
  end

  test "the policy covers API, health, error and static responses" do
    for path <- ["/api/stats", "/health", "/not-found", "/favicon.ico"] do
      conn = get(build_conn(), path)

      assert header(conn, "content-security-policy") =~ "default-src 'self'",
             "missing CSP on #{path}"

      assert header(conn, "x-content-type-options") == "nosniff",
             "missing nosniff on #{path}"

      assert header(conn, "x-frame-options") == "DENY",
             "missing frame denial on #{path}"

      assert header(conn, "referrer-policy") == "strict-origin-when-cross-origin",
             "missing referrer policy on #{path}"
    end
  end

  test "permissions policy denies sensitive browser features", %{conn: conn} do
    policy = conn |> get(~p"/") |> header("permissions-policy")

    assert policy =~ "geolocation=()"
    assert policy =~ "camera=()"
    assert policy =~ "payment=()"
  end

  test "HSTS is not advertised over plain HTTP", %{conn: conn} do
    Application.put_env(:micu_poker, :hsts_enabled, true)

    refute header(get(conn, ~p"/"), "strict-transport-security")
  end

  test "HSTS is advertised when the proxy reports HTTPS", %{conn: conn} do
    Application.put_env(:micu_poker, :hsts_enabled, true)

    hsts =
      conn
      |> put_req_header("x-forwarded-proto", "https")
      |> get(~p"/")
      |> header("strict-transport-security")

    assert hsts =~ "max-age=63072000"
    assert hsts =~ "includeSubDomains"
  end

  test "HSTS stays off when disabled, even over HTTPS", %{conn: conn} do
    Application.put_env(:micu_poker, :hsts_enabled, false)

    refute conn
           |> put_req_header("x-forwarded-proto", "https")
           |> get(~p"/")
           |> header("strict-transport-security")
  end
end
