defmodule MicuPokerWeb.Plugs.SecurityHeaders do
  @moduledoc """
  Adds the response headers Phoenix's `put_secure_browser_headers/2` leaves out.

  Notably a Content-Security-Policy, HSTS, and the cross-origin isolation
  headers. Nginx also sets a few of these, but the app must not depend on a
  correctly configured proxy for its own security posture.

  `style-src` allows inline styles because the poker table positions seats with
  `style="--seat-angle: ..."` custom properties. No inline scripts are used, so
  `script-src` stays strict.
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    conn
    |> put_resp_header("content-security-policy", content_security_policy())
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header("x-permitted-cross-domain-policies", "none")
    |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
    |> put_resp_header(
      "permissions-policy",
      "geolocation=(), microphone=(), camera=(), payment=(), usb=(), interest-cohort=()"
    )
    |> maybe_put_hsts()
  end

  defp maybe_put_hsts(conn) do
    if https?(conn) and hsts_enabled?() do
      put_resp_header(
        conn,
        "strict-transport-security",
        "max-age=63072000; includeSubDomains"
      )
    else
      conn
    end
  end

  # The release itself only speaks plain HTTP on loopback, so the real scheme
  # comes from the proxy. `conn.scheme` is checked too for direct HTTPS setups.
  defp https?(conn) do
    conn.scheme == :https or get_req_header(conn, "x-forwarded-proto") == ["https"]
  end

  defp hsts_enabled? do
    Application.get_env(:micu_poker, :hsts_enabled, false)
  end

  defp content_security_policy do
    case :persistent_term.get({__MODULE__, :csp}, nil) do
      nil ->
        policy = build_policy()
        :persistent_term.put({__MODULE__, :csp}, policy)
        policy

      policy ->
        policy
    end
  end

  defp build_policy do
    [
      "default-src 'self'",
      "base-uri 'self'",
      "object-src 'none'",
      "frame-ancestors 'none'",
      "form-action 'self'",
      "img-src 'self' data:",
      "font-src 'self' data:",
      "style-src 'self' 'unsafe-inline'",
      "script-src 'self'",
      "manifest-src 'self'",
      "connect-src #{Enum.join(connect_sources(), " ")}",
      "upgrade-insecure-requests"
    ]
    |> Enum.join("; ")
  end

  # LiveView and the table channel both open WebSockets back to this host.
  defp connect_sources do
    host = MicuPokerWeb.Endpoint.host()

    ["'self'", "wss://#{host}", "ws://#{host}"]
  end
end
