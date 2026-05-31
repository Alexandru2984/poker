defmodule MicuPokerWeb.DocsController do
  use MicuPokerWeb, :controller

  def show(conn, _params), do: render(conn, :show)
end
