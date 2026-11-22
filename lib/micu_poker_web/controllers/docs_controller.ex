defmodule MicuPokerWeb.DocsController do
  use MicuPokerWeb, :controller

  def show(conn, _params) do
    conn
    |> assign(:page_title, "Documentation & Rules")
    |> assign(:canonical_path, "/docs")
    |> assign(
      :page_description,
      "MicuPoker rules, fictional play-money currencies, table dealer controls, practice AI bots, pot odds HUD and WebSocket protocol documentation."
    )
    |> render(:show)
  end
end
