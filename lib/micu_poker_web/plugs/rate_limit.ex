defmodule MicuPokerWeb.Plugs.RateLimit do
  @moduledoc """
  Per-client rate limiting for HTTP endpoints.

  Buckets are keyed by `{bucket, client_ip}` so an abusive source cannot spend
  another visitor's budget. `MicuPokerWeb.Plugs.RemoteIp` must run first,
  otherwise every request behind nginx shares the loopback key.

  Options:

    * `:bucket` - required atom naming the budget, e.g. `:room_create`
    * `:limit` - hits allowed per window (default `60`)
    * `:window_ms` - window length in milliseconds (default one minute)
    * `:by` - `:ip` (default) or a 1-arity function returning a key part
    * `:message` - flash/JSON message shown when the budget is exhausted
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [put_flash: 3, redirect: 2, json: 2]

  alias MicuPoker.RateLimiter
  alias MicuPokerWeb.Plugs.RemoteIp

  @default_limit 60
  @default_window_ms :timer.minutes(1)

  @impl true
  def init(opts) do
    bucket = Keyword.fetch!(opts, :bucket)

    %{
      bucket: bucket,
      limit: Keyword.get(opts, :limit, @default_limit),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms),
      by: Keyword.get(opts, :by, :ip),
      message: Keyword.get(opts, :message, "Too many requests. Slow down and try again shortly.")
    }
  end

  @impl true
  def call(conn, opts) do
    case RateLimiter.hit({opts.bucket, client_key(conn, opts.by)}, opts.limit, opts.window_ms) do
      {:allow, _remaining} -> conn
      {:deny, retry_after_ms} -> reject(conn, opts, retry_after_ms)
    end
  end

  defp client_key(conn, :ip), do: conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)
  defp client_key(conn, fun) when is_function(fun, 1), do: fun.(conn)

  defp reject(conn, opts, retry_after_ms) do
    retry_after_seconds = max(div(retry_after_ms, 1000), 1)

    conn =
      conn
      |> put_resp_header("retry-after", Integer.to_string(retry_after_seconds))
      |> put_status(:too_many_requests)

    if json_request?(conn) do
      conn
      |> json(%{error: "rate_limited", retry_after: retry_after_seconds})
      |> halt()
    else
      conn
      |> put_flash(:error, opts.message)
      |> redirect(to: redirect_target(conn))
      |> halt()
    end
  end

  defp json_request?(conn) do
    "application/json" in get_req_header(conn, "accept") or
      String.starts_with?(conn.request_path, "/api/")
  end

  # A rejected POST must not bounce the visitor back to the URL it came from
  # when that URL is the same POST target, so fall back to the lobby.
  defp redirect_target(conn) do
    case get_req_header(conn, "referer") do
      [referer | _rest] -> same_origin_path(referer) || "/lobby"
      [] -> "/lobby"
    end
  end

  defp same_origin_path(referer) do
    uri = URI.parse(referer)

    if uri.host in [nil, MicuPokerWeb.Endpoint.host()] and is_binary(uri.path) and
         String.starts_with?(uri.path, "/") do
      uri.path
    end
  end
end
