defmodule MicuPokerWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :micu_poker

  # Session options live in config so `:secure` can be switched on for prod
  # without forking this module. The cookie is signed *and* encrypted, so the
  # session payload (guest id, auth token) is opaque to the browser.
  @session_options Application.compile_env!(:micu_poker, :session_options)

  # `:peer_data` and `:x_headers` let socket transports resolve the real client
  # IP through MicuPokerWeb.Plugs.RemoteIp; without them every WebSocket looks
  # like it originated from the nginx loopback address.
  @connect_info [:peer_data, :x_headers, :uri, session: @session_options]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: @connect_info],
    longpoll: [connect_info: @connect_info]

  socket "/socket", MicuPokerWeb.UserSocket,
    websocket: [connect_info: @connect_info],
    longpoll: false

  # Serve at "/" the static files from "priv/static" directory.
  plug Plug.Static,
    at: "/",
    from: :micu_poker,
    gzip: true,
    only: MicuPokerWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :micu_poker
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId

  # Must run before anything that logs or rate limits, otherwise every request
  # is attributed to the nginx loopback address.
  plug MicuPokerWeb.Plugs.RemoteIp

  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    length: 512_000,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug MicuPokerWeb.Router
end
