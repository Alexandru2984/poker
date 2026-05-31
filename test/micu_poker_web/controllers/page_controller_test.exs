defmodule MicuPokerWeb.PageControllerTest do
  use MicuPokerWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/lobby"
  end
end
