defmodule MicuPokerWeb.PageControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo

  test "GET / serves the landing page", %{conn: conn} do
    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ "MicuPoker"
    assert html =~ "Play now"
    assert html =~ "Virtual demo chips only"
  end

  test "the landing page links into the app without entering it", %{conn: conn} do
    html = html_response(get(conn, ~p"/"), 200)

    assert html =~ ~s(href="/lobby")
    assert html =~ ~s(href="/register")
  end

  test "public pages do not create guest users", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    assert html_response(get(conn, ~p"/"), 200)

    conn = get(build_conn(), ~p"/docs")
    assert html_response(conn, 200) =~ "MicuPoker Documentation"

    assert Repo.aggregate(User, :count) == before_count
  end
end
