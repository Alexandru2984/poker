defmodule MicuPokerWeb.LobbyLiveTest do
  use MicuPokerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MicuPoker.Accounts

  test "lobby form labels are connected to their inputs", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ ~s(for="user_username")
    assert html =~ "Display name"
    assert html =~ ~s(for="room_name")
    assert html =~ "Room name"
    assert html =~ ~s(for="room_max_players")
    assert html =~ "Max players"
    assert html =~ ~s(for="room_starting_chips")
    assert html =~ "Starting chips"
    assert html =~ ~s(for="room_small_blind")
    assert html =~ "Small blind"
    assert html =~ ~s(for="room_big_blind")
    assert html =~ "Big blind"
  end
end
