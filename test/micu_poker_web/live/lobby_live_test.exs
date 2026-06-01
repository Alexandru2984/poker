defmodule MicuPokerWeb.LobbyLiveTest do
  use MicuPokerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo

  test "lobby creates a guest session lazily", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ "MicuPoker"
    assert Repo.aggregate(User, :count) == before_count + 1
  end

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

  test "lobby form uses configured table defaults", %{conn: conn} do
    with_env(%{
      "DEFAULT_STARTING_CHIPS" => "1500",
      "DEFAULT_SMALL_BLIND" => "15",
      "DEFAULT_BIG_BLIND" => "30"
    })

    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ ~s(name="room[starting_chips]")
    assert html =~ ~s(value="1500")
    assert html =~ ~s(name="room[small_blind]")
    assert html =~ ~s(value="15")
    assert html =~ ~s(name="room[big_blind]")
    assert html =~ ~s(value="30")
  end

  defp with_env(values) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end
end
