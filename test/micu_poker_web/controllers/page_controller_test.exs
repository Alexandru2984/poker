defmodule MicuPokerWeb.PageControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/lobby"
  end

  test "public pages do not create guest users", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/lobby"

    conn = get(build_conn(), ~p"/docs")
    assert html_response(conn, 200) =~ "MicuPoker Documentation"

    assert Repo.aggregate(User, :count) == before_count
  end
end
