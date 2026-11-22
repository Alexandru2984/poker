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
    |> assign(:page_title, "Play-money Texas Hold'em Simulator")
    |> assign(:canonical_path, "/")
    |> assign(
      :page_description,
      "Free play-money multiplayer Texas Hold'em poker simulator with fictional currencies, dealer table controls, practice AI bots, pot odds HUD and side pots. Zero real money."
    )
    |> render(:home, stats: stats(), open_tables: open_tables())
  end

  def sitemap(conn, _params) do
    base = MicuPokerWeb.Endpoint.url()

    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
      <url><loc>#{base}/</loc><changefreq>daily</changefreq><priority>1.0</priority></url>
      <url><loc>#{base}/lobby</loc><changefreq>always</changefreq><priority>0.9</priority></url>
      <url><loc>#{base}/leaderboard</loc><changefreq>hourly</changefreq><priority>0.8</priority></url>
      <url><loc>#{base}/docs</loc><changefreq>weekly</changefreq><priority>0.7</priority></url>
      <url><loc>#{base}/login</loc><changefreq>monthly</changefreq><priority>0.4</priority></url>
      <url><loc>#{base}/register</loc><changefreq>monthly</changefreq><priority>0.4</priority></url>
    </urlset>
    """

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, String.trim(xml))
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
