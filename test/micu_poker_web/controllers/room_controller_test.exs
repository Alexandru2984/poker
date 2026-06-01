defmodule MicuPokerWeb.RoomControllerTest do
  use MicuPokerWeb.ConnCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableSupervisor

  test "join redirects invalid room ids to lobby without starting a table", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    conn = post(conn, ~p"/rooms/not-a-number/join")

    assert redirected_to(conn) == ~p"/lobby"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Table was not found."
    assert :not_found = TableSupervisor.lookup_table(-1)
  end

  test "leave redirects invalid room ids to lobby", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    conn = post(conn, ~p"/rooms/not-a-number/leave")

    assert redirected_to(conn) == ~p"/lobby"
  end
end
