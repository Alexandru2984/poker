defmodule MicuPokerWeb.PageController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Rooms

  @doc """
  The public landing page.

  This used to redirect straight to `/lobby`, which sits behind the guest
  pipeline, so every crawler and every link preview minted a `users` row. The
  landing page is now served directly and creates nothing.
  """
  def home(conn, _params) do
    conn
    |> assign(:page_title, "Play-money Texas Hold'em")
    |> render(:home, stats: stats(), open_tables: open_tables())
  end

  defp stats do
    Rooms.stats()
  rescue
    _database_unavailable -> %{rooms: 0, active_rooms: 0, users: 0, completed_hands: 0}
  end

  defp open_tables do
    Rooms.list_rooms()
    |> Enum.filter(&(&1.player_count < &1.max_players))
    |> Enum.take(5)
  rescue
    _database_unavailable -> []
  end
end
