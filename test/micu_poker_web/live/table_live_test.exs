defmodule MicuPokerWeb.TableLiveTest do
  use MicuPokerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableServer
  alias MicuPoker.Rooms

  defp join_connected(room, user) do
    assert {:ok, _state} = TableServer.join(room.id, user.id)
    TableServer.connect(room.id, user.id, make_ref())
  end

  test "table page shows invite id and invite link", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Invite Test",
          "max_players" => "2",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user.id
      )

    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    {:ok, _view, html} = live(conn, ~p"/rooms/#{room.id}")

    assert html =~ "Invite Table"
    assert html =~ "Table ##{room.id}"
    assert html =~ "/rooms/#{room.id}"
  end

  test "mobile table view shows a late joiner as waiting instead of corrupting the hand", %{
    conn: conn
  } do
    {:ok, user_one} = Accounts.create_guest_user()
    {:ok, user_two} = Accounts.create_guest_user()
    {:ok, user_three} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Mobile Waiting Test",
          "max_players" => "3",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user_one.id
      )

    start_supervised!({TableServer, room.id})
    assert {:ok, _} = join_connected(room, user_one)
    assert {:ok, _} = join_connected(room, user_two)

    conn =
      conn
      |> Plug.Conn.put_req_header(
        "user-agent",
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
      )
      |> Plug.Test.init_test_session(guest_user_id: user_three.id)

    {:ok, _view, html} = live(conn, ~p"/rooms/#{room.id}")

    assert html =~ "Invite Table"
    assert html =~ "Your Hand"
    assert html =~ "Waiting next hand"
    assert html =~ "Table ##{room.id}"

    view_one = TableServer.state(room.id, user_one.id)
    assert Enum.find(view_one.players, &(&1.user_id == user_one.id)).cards |> length() == 2
    assert Enum.find(view_one.players, &(&1.user_id == user_two.id)).cards |> length() == 2
    assert Enum.find(view_one.players, &(&1.user_id == user_three.id)).cards == []
  end

  test "player table view includes an explicit own-hand panel", %{conn: conn} do
    {:ok, user_one} = Accounts.create_guest_user()
    {:ok, user_two} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Own Hand Test",
          "max_players" => "2",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user_one.id
      )

    start_supervised!({TableServer, room.id})
    assert {:ok, _} = join_connected(room, user_one)
    assert {:ok, _} = join_connected(room, user_two)

    conn = Plug.Test.init_test_session(conn, guest_user_id: user_one.id)
    {:ok, _view, html} = live(conn, ~p"/rooms/#{room.id}")

    user_one_view = TableServer.state(room.id, user_one.id)
    own_cards = Enum.find(user_one_view.players, &(&1.user_id == user_one.id)).cards

    assert html =~ "Your Hand"
    assert length(own_cards) == 2

    for card <- own_cards do
      assert html =~ card.rank_label
      assert html =~ card.suit_symbol
    end
  end

  test "full room with spectators disabled redirects late viewers to lobby", %{conn: conn} do
    {:ok, user_one} = Accounts.create_guest_user()
    {:ok, user_two} = Accounts.create_guest_user()
    {:ok, user_three} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "No Spectators Test",
          "max_players" => "2",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000",
          "spectator_enabled" => "false"
        },
        user_one.id
      )

    start_supervised!({TableServer, room.id})
    assert {:ok, _} = join_connected(room, user_one)
    assert {:ok, _} = join_connected(room, user_two)

    conn = Plug.Test.init_test_session(conn, guest_user_id: user_three.id)

    assert {:error, {:live_redirect, %{to: "/lobby", flash: flash}}} =
             live(conn, ~p"/rooms/#{room.id}")

    assert flash["error"] == "Table is full and spectators are disabled."
  end
end
