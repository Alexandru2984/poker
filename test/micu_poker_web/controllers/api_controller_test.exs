defmodule MicuPokerWeb.ApiControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.User
  alias MicuPoker.Poker.{TableServer, TableSupervisor}
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

  test "room API returns JSON 404 for invalid or missing room ids", %{conn: conn} do
    conn = get(conn, ~p"/api/rooms/not-a-number")
    assert %{"error" => "room_not_found"} = json_response(conn, 404)

    conn = get(build_conn(), ~p"/api/rooms/999999999")
    assert %{"error" => "room_not_found"} = json_response(conn, 404)
  end

  test "public room API does not reveal folded cards after uncontested hands", %{conn: conn} do
    {:ok, user_one} = Accounts.create_guest_user()
    {:ok, user_two} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "API Privacy Room",
          "max_players" => "2",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user_one.id
      )

    start_supervised!({TableServer, room.id})
    assert {:ok, _state} = join_connected(room, user_one)
    assert {:ok, _state} = join_connected(room, user_two)

    acting_user_id = acting_user_id(room, [user_one, user_two])

    assert :ok = TableServer.act(room.id, acting_user_id, "fold", 0)

    conn = get(conn, ~p"/api/rooms/#{room.id}")

    assert %{"table" => %{"stage" => "complete", "players" => players}} =
             json_response(conn, 200)

    for player <- players, player["in_hand"] do
      refute Map.has_key?(player, "user_id")
      assert player["is_me"] == false
      assert Enum.all?(player["cards"], &(&1 == %{"hidden" => true}))
      assert player["hand_summary"] == nil
    end
  end

  defp join_connected(room, user) do
    assert {:ok, _state} = TableServer.join(room.id, user.id)
    TableServer.connect(room.id, user.id, make_ref())
  end

  defp acting_user_id(room, users) do
    users
    |> Enum.find(fn user -> TableServer.state(room.id, user.id).valid_actions.actions != [] end)
    |> Map.fetch!(:id)
  end
end
