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

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:micu_poker, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MicuPokerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
