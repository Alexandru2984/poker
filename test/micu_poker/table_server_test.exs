defmodule MicuPoker.Poker.TableServerTest do
  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableServer
  alias MicuPoker.Rooms

  setup do
    {:ok, user_one} = Accounts.create_guest_user()
    {:ok, user_two} = Accounts.create_guest_user()
    {:ok, user_three} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Two User Test",
          "max_players" => "3",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        user_one.id
      )

    start_supervised!({TableServer, room.id})

    %{room: room, user_one: user_one, user_two: user_two, user_three: user_three}
  end

  defp with_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  test "separate users can sit at the same table and start a hand", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, state_one_waiting} = TableServer.join(room.id, user_one.id)
    assert [%{user_id: user_one_id}] = state_one_waiting.players
    assert user_one_id == user_one.id
    assert state_one_waiting.stage == :waiting

    assert {:ok, state_two} = TableServer.join(room.id, user_two.id)

    assert state_two.stage == :preflop
    assert length(state_two.players) == 2

    assert Enum.map(state_two.players, & &1.user_id) |> Enum.sort() ==
             Enum.sort([user_one.id, user_two.id])

    assert Enum.map(state_two.players, & &1.seat_number) |> Enum.sort() == [1, 2]
    assert state_two.pot == room.small_blind + room.big_blind
  end

  test "room status follows table occupancy", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert Rooms.get_room!(room.id).status == "complete"

    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert Rooms.get_room!(room.id).status == "waiting"

    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)
    assert Rooms.get_room!(room.id).status == "active"

    assert :ok = TableServer.leave(room.id, user_one.id)
    assert Rooms.get_room!(room.id).status == "waiting"
  end

  test "each seated user sees only their own private cards before showdown", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)

    view_one = TableServer.state(room.id, user_one.id)
    view_two = TableServer.state(room.id, user_two.id)

    user_one_in_view_one = Enum.find(view_one.players, &(&1.user_id == user_one.id))
    user_two_in_view_one = Enum.find(view_one.players, &(&1.user_id == user_two.id))
    user_one_in_view_two = Enum.find(view_two.players, &(&1.user_id == user_one.id))
    user_two_in_view_two = Enum.find(view_two.players, &(&1.user_id == user_two.id))

    assert length(user_one_in_view_one.cards) == 2
    assert Enum.all?(user_one_in_view_one.cards, &Map.has_key?(&1, :label))

    assert user_one_in_view_one.hand_summary.title in [
             "High card",
             "Pocket pair",
             "Suited hand",
             "Suited connector",
             "Connector"
           ]

    assert Enum.all?(user_two_in_view_one.cards, &(&1 == %{hidden: true}))
    assert user_two_in_view_one.hand_summary == nil

    assert Enum.all?(user_one_in_view_two.cards, &(&1 == %{hidden: true}))
    assert user_one_in_view_two.hand_summary == nil
    assert length(user_two_in_view_two.cards) == 2
    assert Enum.all?(user_two_in_view_two.cards, &Map.has_key?(&1, :label))

    assert user_two_in_view_two.hand_summary.title in [
             "High card",
             "Pocket pair",
             "Suited hand",
             "Suited connector",
             "Connector"
           ]
  end

  test "only the user whose turn it is receives valid turn actions", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)

    view_one = TableServer.state(room.id, user_one.id)
    view_two = TableServer.state(room.id, user_two.id)

    actions_one = view_one.valid_actions.actions
    actions_two = view_two.valid_actions.actions

    assert (actions_one == [] and actions_two != []) or (actions_one != [] and actions_two == [])
  end

  test "joining after a hand starts does not erase private cards and waits for next hand", %{
    room: room,
    user_one: user_one,
    user_two: user_two,
    user_three: user_three
  } do
    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)

    before_join_one = TableServer.state(room.id, user_one.id)
    before_join_two = TableServer.state(room.id, user_two.id)
    first_user_cards = Enum.find(before_join_one.players, &(&1.user_id == user_one.id)).cards
    second_user_cards = Enum.find(before_join_two.players, &(&1.user_id == user_two.id)).cards

    assert length(first_user_cards) == 2
    assert length(second_user_cards) == 2

    assert {:ok, state_three} = TableServer.join(room.id, user_three.id)
    waiting_player = Enum.find(state_three.players, &(&1.user_id == user_three.id))
    assert waiting_player.in_hand == false
    assert waiting_player.cards == []
    assert state_three.valid_actions.actions == []

    after_join_one = TableServer.state(room.id, user_one.id)
    after_join_two = TableServer.state(room.id, user_two.id)

    assert Enum.find(after_join_one.players, &(&1.user_id == user_one.id)).cards ==
             first_user_cards

    assert Enum.find(after_join_two.players, &(&1.user_id == user_two.id)).cards ==
             second_user_cards

    assert Enum.find(after_join_one.players, &(&1.user_id == user_three.id)).cards == []
  end

  test "manual leave during a hand folds and does not re-seat the player next hand", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)

    assert :ok = TableServer.leave(room.id, user_one.id)
    [{pid, _value}] = Registry.lookup(MicuPoker.TableRegistry, room.id)
    send(pid, :start_next_hand)

    Process.sleep(30)

    state = TableServer.state(room.id, user_two.id)
    refute Enum.any?(state.players, &(&1.user_id == user_one.id))
    assert Enum.any?(state.players, &(&1.user_id == user_two.id))
    assert state.stage == :waiting
  end

  test "disconnect keeps a seat reserved and join reconnects it", %{
    room: room,
    user_one: user_one
  } do
    with_env("DISCONNECT_GRACE_SECONDS", "30")

    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert :ok = TableServer.disconnect(room.id, user_one.id)

    disconnected = TableServer.state(room.id, user_one.id)
    player = Enum.find(disconnected.players, &(&1.user_id == user_one.id))
    assert player.connected == false
    assert player.disconnect_deadline

    assert {:ok, reconnected} = TableServer.join(room.id, user_one.id)
    player = Enum.find(reconnected.players, &(&1.user_id == user_one.id))
    assert player.connected == true
    assert player.disconnect_deadline == nil
  end

  test "disconnect grace expiry removes a waiting player", %{room: room, user_one: user_one} do
    with_env("DISCONNECT_GRACE_SECONDS", "0")

    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert :ok = TableServer.disconnect(room.id, user_one.id)

    Process.sleep(30)

    state = TableServer.state(room.id, user_one.id)
    refute Enum.any?(state.players, &(&1.user_id == user_one.id))
  end

  test "rate limits table chat", %{room: room, user_one: user_one} do
    with_env("CHAT_RATE_LIMIT_MS", "5000")

    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert :ok = TableServer.chat(room.id, user_one.id, "hello")
    assert {:error, :rate_limited} = TableServer.chat(room.id, user_one.id, "too fast")
  end

  test "rate limits repeated action attempts", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    with_env("ACTION_RATE_LIMIT_MS", "5000")

    assert {:ok, _state_one} = TableServer.join(room.id, user_one.id)
    assert {:ok, _state_two} = TableServer.join(room.id, user_two.id)

    state = TableServer.state(room.id)
    current = Enum.find(state.players, &(&1.seat_number == state.turn_seat))

    assert {:error, :invalid_action} = TableServer.act(room.id, current.user_id, "bogus", 0)
    assert {:error, :rate_limited} = TableServer.act(room.id, current.user_id, "fold", 0)
  end
end
