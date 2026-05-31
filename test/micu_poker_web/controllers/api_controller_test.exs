defmodule MicuPokerWeb.ApiControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.User
  alias MicuPoker.Poker.TableSupervisor
  alias MicuPoker.Repo
  alias MicuPoker.Rooms

  test "public API endpoints do not create guest users", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    conn = get(conn, ~p"/api/stats")
    assert %{"play_money_only" => true} = json_response(conn, 200)

    conn = get(build_conn(), ~p"/api/rooms")
    assert %{"rooms" => rooms} = json_response(conn, 200)
    assert is_list(rooms)

    assert Repo.aggregate(User, :count) == before_count
  end

  test "room API does not start table processes", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "API Passive Room",
          "max_players" => "6",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user.id
      )

    assert :not_found = TableSupervisor.lookup_table(room.id)

    conn = get(conn, ~p"/api/rooms/#{room.id}")

    assert %{"room" => %{"id" => room_id}, "table" => nil} = json_response(conn, 200)
    assert room_id == room.id
    assert :not_found = TableSupervisor.lookup_table(room.id)
  end
end
