defmodule MicuPokerWeb.LeaderboardController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Stats

  def index(conn, _params) do
    render(conn, :index,
      page_title: "Leaderboard",
      leaders: Stats.leaderboard(25),
      my_stats: my_stats(conn)
    )
  end

  # Guests get their numbers too, they just do not survive losing the cookie.
  defp my_stats(conn) do
    case conn.assigns[:current_user] do
      nil -> nil
      user -> Stats.player_stats(user.id)
    end
  end
end
