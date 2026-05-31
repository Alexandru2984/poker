defmodule MicuPokerWeb.ApiControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo

  test "public API endpoints do not create guest users", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    conn = get(conn, ~p"/api/stats")
    assert %{"play_money_only" => true} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/rooms")
    assert %{"rooms" => rooms} = json_response(conn, 200)
    assert is_list(rooms)

    assert Repo.aggregate(User, :count) == before_count
  end
end
