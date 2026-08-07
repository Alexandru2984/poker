defmodule MicuPokerWeb.LeaderboardControllerTest do
  use MicuPokerWeb.ConnCase, async: true

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo
  alias MicuPoker.Rooms

  defp played_hand(room, user, delta) do
    {:ok, hand} = Rooms.create_hand(room.id, System.unique_integer([:positive]))

    {:ok, _} =
      Rooms.record_ledger([
        %{
          user_id: user.id,
          room_id: room.id,
          hand_id: hand.id,
          delta: delta,
          reason: "showdown"
        }
      ])
  end

  setup do
    {:ok, user} = Accounts.create_guest_user()
    {:ok, room} = Rooms.create_room(%{"name" => "Leaderboard Table"}, user.id)

    %{user: user, room: room}
  end

  test "renders an empty state before any hands", %{conn: conn} do
    html = html_response(get(conn, ~p"/leaderboard"), 200)

    assert html =~ "Leaderboard"
    assert html =~ "No hands have been played yet"
  end

  test "lists players ranked by chips won", %{conn: conn, room: room, user: user} do
    played_hand(room, user, 750)

    html = html_response(get(conn, ~p"/leaderboard"), 200)

    assert html =~ user.username
    assert html =~ "+750"
  end

  test "shows a loss as negative", %{conn: conn, room: room, user: user} do
    played_hand(room, user, -320)

    assert html_response(get(conn, ~p"/leaderboard"), 200) =~ "-320"
  end

  test "does not create a guest user for a visitor", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    assert html_response(get(conn, ~p"/leaderboard"), 200)
    assert Repo.aggregate(User, :count) == before_count
  end

  test "shows personal numbers to a player with a session", %{conn: conn, room: room, user: user} do
    played_hand(room, user, 400)

    html =
      conn
      |> Plug.Test.init_test_session(guest_user_id: user.id)
      |> get(~p"/leaderboard")
      |> html_response(200)

    assert html =~ "Your numbers"
    assert html =~ "VPIP"
  end

  test "hides the personal panel from an anonymous visitor", %{conn: conn} do
    refute html_response(get(conn, ~p"/leaderboard"), 200) =~ "Your numbers"
  end
end
