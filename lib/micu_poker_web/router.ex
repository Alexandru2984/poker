defmodule MicuPokerWeb.Router do
  use MicuPokerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MicuPokerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"x-frame-options" => "DENY"}
  end

  pipeline :guest_browser do
    plug MicuPokerWeb.Plugs.GuestSession
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_session
  end

  pipeline :health_api do
    plug :accepts, ["json"]
  end

  scope "/", MicuPokerWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/docs", DocsController, :show
  end

  scope "/", MicuPokerWeb do
    pipe_through [:browser, :guest_browser]

    post "/rooms", RoomController, :create
    post "/rooms/:id/join", RoomController, :join
    post "/rooms/:id/leave", RoomController, :leave

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
