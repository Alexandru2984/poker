defmodule MicuPokerWeb.HealthController do
  use MicuPokerWeb, :controller

  def show(conn, _params) do
    json(conn, %{status: "ok", service: "micupoker"})
  end
end
