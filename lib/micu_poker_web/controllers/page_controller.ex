defmodule MicuPokerWeb.PageController do
  use MicuPokerWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/lobby")
  end
end
