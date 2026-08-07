defmodule MicuPokerWeb.Router do
  use MicuPokerWeb, :router

  import MicuPokerWeb.UserAuth, only: [fetch_current_user: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MicuPokerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"x-frame-options" => "DENY"}
    plug MicuPokerWeb.Plugs.SecurityHeaders
    plug :fetch_current_user
  end

  # Creates a throwaway identity for visitors who are not signed in. Only on app
  # routes: public pages must not insert a users row for every crawler hit.
  pipeline :guest_browser do
    plug MicuPokerWeb.Plugs.GuestSession
  end

  pipeline :auth_writes do
    plug MicuPokerWeb.Plugs.RateLimit,
      bucket: :auth_write,
      limit: 20,
      window_ms: 60_000,
      message: "Too many attempts from this network. Wait a minute and try again."
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session

    plug MicuPokerWeb.Plugs.RateLimit,
      bucket: :public_api,
      limit: 120,
      window_ms: 60_000
  end

  pipeline :health_api do
    plug :accepts, ["json"]
  end

  # Room creation writes to the database and counts against MAX_ROOMS, so it is
  # the cheapest endpoint to abuse. Keep it on a much tighter budget than reads.
  pipeline :room_writes do
    plug MicuPokerWeb.Plugs.RateLimit,
      bucket: :room_create,
      limit: 10,
      window_ms: 60_000,
      message: "You are creating or joining tables too quickly. Wait a moment."
  end

  scope "/", MicuPokerWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/docs", DocsController, :show
    get "/leaderboard", LeaderboardController, :index
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete
  end

  scope "/", MicuPokerWeb do
    pipe_through [:browser, :auth_writes]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
  end

  scope "/", MicuPokerWeb do
    pipe_through [:browser, :guest_browser, :room_writes]

    post "/rooms", RoomController, :create
    post "/rooms/:id/join", RoomController, :join
    post "/rooms/:id/leave", RoomController, :leave
    get "/rooms/:id/unlock", RoomController, :unlock
    post "/rooms/:id/unlock", RoomController, :submit_unlock
  end

  scope "/", MicuPokerWeb do
    pipe_through [:browser, :guest_browser]

    live_session :guest, on_mount: [{MicuPokerWeb.UserAuth, :default}] do
      live "/lobby", LobbyLive, :index
      live "/rooms/:id", TableLive, :show
    end
  end

  scope "/", MicuPokerWeb do
    pipe_through :health_api

    get "/health", HealthController, :show
  end

  scope "/", MicuPokerWeb do
    pipe_through :api

    get "/api/rooms", ApiController, :rooms
    get "/api/rooms/:id", ApiController, :room
    get "/api/stats", ApiController, :stats
  end

  import Phoenix.LiveDashboard.Router

  # LiveDashboard exposes process, memory and query internals, so outside dev it
  # is only mounted when ADMIN_USER and ADMIN_PASSWORD are both configured, and
  # then only behind basic auth over HTTPS.
  scope "/admin" do
    pipe_through [:browser, :admin_auth]

    live_dashboard "/dashboard",
      metrics: MicuPokerWeb.Telemetry,
      ecto_repos: [MicuPoker.Repo]
  end

  if Application.compile_env(:micu_poker, :dev_routes) do
    scope "/dev" do
      pipe_through :browser

      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  defp admin_auth(conn, _opts) do
    case admin_credentials() do
      {username, password} ->
        Plug.BasicAuth.basic_auth(conn,
          username: username,
          password: password,
          realm: "MicuPoker"
        )

      nil ->
        conn
        |> Plug.Conn.send_resp(:not_found, "")
        |> Plug.Conn.halt()
    end
  end

  defp admin_credentials do
    username = System.get_env("ADMIN_USER")
    password = System.get_env("ADMIN_PASSWORD")

    # A short password here would be brute-forceable; refuse rather than mount a
    # weakly protected dashboard.
    if is_binary(username) and is_binary(password) and username != "" and
         byte_size(password) >= 16 do
      {username, password}
    end
  end
end
