defmodule MicuPoker.Poker.TableServerTest do
  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Repo
  alias MicuPoker.Rooms
  alias MicuPoker.Rooms.{ChipLedger, Hand, RoomPlayer}

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

  defp join_connected(room, user, ref \\ make_ref()) do
    assert {:ok, _state} = TableServer.join(room.id, user.id)
    TableServer.connect(room.id, user.id, ref)
  end

  defp own_player(view), do: Enum.find(view.players, &Map.get(&1, :is_me, false))

  defp other_players(view), do: Enum.reject(view.players, &Map.get(&1, :is_me, false))

  defp acting_user_id(room, users) do
    users
    |> Enum.find(fn user -> TableServer.state(room.id, user.id).valid_actions.actions != [] end)
    |> Map.fetch!(:id)
  end

  defp player_stack(room, user) do
    room.id
    |> TableServer.state(user.id)
    |> own_player()
    |> Map.fetch!(:stack)
  end

  test "separate users can sit at the same table and start a hand", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, state_one_waiting} = join_connected(room, user_one)
    assert [%{user_id: user_one_id}] = state_one_waiting.players
    assert user_one_id == user_one.id
    assert state_one_waiting.stage == :waiting

    assert {:ok, state_two} = join_connected(room, user_two)

    assert state_two.stage == :preflop
    assert length(state_two.players) == 2

    assert own_player(state_two).user_id == user_two.id
    assert Enum.all?(other_players(state_two), &(not Map.has_key?(&1, :user_id)))

    assert Enum.map(state_two.players, & &1.seat_number) |> Enum.sort() == [1, 2]
    assert state_two.pot == room.small_blind + room.big_blind
  end

  test "room status follows table occupancy", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert Rooms.get_room!(room.id).status == "complete"

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert Rooms.get_room!(room.id).status == "waiting"

    assert {:ok, _state_two} = join_connected(room, user_two)
    assert Rooms.get_room!(room.id).status == "active"

    assert :ok = TableServer.leave(room.id, user_one.id)
    assert Rooms.get_room!(room.id).status == "waiting"
  end

  test "each seated user sees only their own private cards before showdown", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    view_one = TableServer.state(room.id, user_one.id)
    view_two = TableServer.state(room.id, user_two.id)

    user_one_in_view_one = own_player(view_one)
    user_two_in_view_one = other_players(view_one) |> List.first()
    user_one_in_view_two = other_players(view_two) |> List.first()
    user_two_in_view_two = own_player(view_two)

    assert length(user_one_in_view_one.cards) == 2
    assert Enum.all?(user_one_in_view_one.cards, &Map.has_key?(&1, :label))
    assert user_one_in_view_one.user_id == user_one.id
    refute Map.has_key?(user_two_in_view_one, :user_id)

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
    refute Map.has_key?(user_one_in_view_two, :user_id)
    assert length(user_two_in_view_two.cards) == 2
    assert Enum.all?(user_two_in_view_two.cards, &Map.has_key?(&1, :label))
    assert user_two_in_view_two.user_id == user_two.id

    assert user_two_in_view_two.hand_summary.title in [
             "High card",
             "Pocket pair",
             "Suited hand",
             "Suited connector",
             "Connector"
           ]
  end

  test "uncontested complete hands do not reveal folded private cards", %{
    room: room,
    user_one: user_one,
    user_two: user_two,
    user_three: user_three
  } do
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    acting_user_id = acting_user_id(room, [user_one, user_two])

    assert :ok = TableServer.act(room.id, acting_user_id, "fold", 0)

    public_view = TableServer.state(room.id, nil)
    spectator_view = TableServer.state(room.id, user_three.id)

    for view <- [public_view, spectator_view] do
      assert view.stage == :complete

      for player <- view.players, player.in_hand do
        assert Enum.all?(player.cards, &(&1 == %{hidden: true}))
        assert player.hand_summary == nil
      end
    end

    acting_view = TableServer.state(room.id, acting_user_id)
    acting_player = own_player(acting_view)
    assert length(acting_player.cards) == 2
    assert Enum.all?(acting_player.cards, &Map.has_key?(&1, :label))
  end

  test "only the user whose turn it is receives valid turn actions", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

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
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    before_join_one = TableServer.state(room.id, user_one.id)
    before_join_two = TableServer.state(room.id, user_two.id)
    first_user_cards = own_player(before_join_one).cards
    second_user_cards = own_player(before_join_two).cards

    assert length(first_user_cards) == 2
    assert length(second_user_cards) == 2

    assert {:ok, _state_three} = TableServer.join(room.id, user_three.id)
    assert {:ok, state_three} = TableServer.connect(room.id, user_three.id, make_ref())
    waiting_player = own_player(state_three)
    assert waiting_player.in_hand == false
    assert waiting_player.cards == []
    assert state_three.valid_actions.actions == []

    after_join_one = TableServer.state(room.id, user_one.id)
    after_join_two = TableServer.state(room.id, user_two.id)

    assert own_player(after_join_one).cards == first_user_cards

    assert own_player(after_join_two).cards == second_user_cards

    assert Enum.any?(after_join_one.players, &(&1.cards == [] and &1.in_hand == false))
  end

  test "full rooms allow spectators only when spectator mode is enabled", %{
    user_one: user_one,
    user_two: user_two,
    user_three: user_three
  } do
    {:ok, spectator_room} = create_test_room(user_one, "Spectator On", true)
    assert {:ok, _pid} = TableSupervisor.ensure_table(spectator_room.id)

    assert {:ok, _} = join_connected(spectator_room, user_one)
    assert {:ok, _} = join_connected(spectator_room, user_two)
    assert {:spectator, spectator_state} = TableServer.join(spectator_room.id, user_three.id)
    refute Enum.any?(spectator_state.players, &Map.get(&1, :is_me, false))

    {:ok, private_room} = create_test_room(user_one, "Spectator Off", false)
    assert {:ok, _pid} = TableSupervisor.ensure_table(private_room.id)

    assert {:ok, _} = join_connected(private_room, user_one)
    assert {:ok, _} = join_connected(private_room, user_two)
    assert {:error, :room_full} = TableServer.join(private_room.id, user_three.id)
  end

  test "manual leave during a hand folds and does not re-seat the player next hand", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    assert :ok = TableServer.leave(room.id, user_one.id)
    [{pid, _value}] = Registry.lookup(MicuPoker.TableRegistry, room.id)
    send(pid, :start_next_hand)

    Process.sleep(30)

    state = TableServer.state(room.id, user_two.id)
    assert own_player(state).user_id == user_two.id
    assert Enum.all?(other_players(state), &(not Map.has_key?(&1, :user_id)))
    assert state.stage == :waiting
  end

  test "finished hands persist stacks, pot total, and chip ledger", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    acting_user_id = acting_user_id(room, [user_one, user_two])

    assert :ok = TableServer.act(room.id, acting_user_id, "fold", 0)

    persisted_players =
      RoomPlayer
      |> Repo.all()
      |> Enum.filter(&(&1.room_id == room.id))
      |> Map.new(&{&1.user_id, &1.stack})

    in_memory_players =
      Map.new([user_one, user_two], fn user -> {user.id, player_stack(room, user)} end)

    assert persisted_players == in_memory_players

    hand = Repo.one!(Hand)
    assert hand.room_id == room.id
    assert hand.pot_total == room.small_blind + room.big_blind

    assert [%{"amount" => amount, "hand" => "uncontested", "username" => username} = winner] =
             hand.winner_summary["winners"]

    assert is_integer(amount)
    assert is_binary(username)
    refute Map.has_key?(winner, "user_id")

    ledger =
      ChipLedger
      |> Repo.all()
      |> Enum.filter(&(&1.room_id == room.id and &1.hand_id == hand.id))
      |> Map.new(&{&1.user_id, &1.delta})

    assert ledger |> Map.values() |> Enum.sum() == 0
    assert map_size(ledger) == 2
  end

  test "completed hands schedule the next hand with configured delay", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    with_env("NEXT_HAND_DELAY_MS", "10")

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    acting_user_id = acting_user_id(room, [user_one, user_two])

    assert :ok = TableServer.act(room.id, acting_user_id, "fold", 0)
    assert TableServer.state(room.id).stage == :complete

    Process.sleep(30)

    state = TableServer.state(room.id)
    assert state.hand_number == 2
    assert state.stage == :preflop
  end

  test "disconnect keeps a seat reserved and join reconnects it", %{
    room: room,
    user_one: user_one
  } do
    with_env("DISCONNECT_GRACE_SECONDS", "30")

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert :ok = TableServer.disconnect(room.id, user_one.id)

    disconnected = TableServer.state(room.id, user_one.id)
    player = Enum.find(disconnected.players, &(&1.user_id == user_one.id))
    assert player.connected == false
    assert player.disconnect_deadline

    assert {:ok, _state} = TableServer.join(room.id, user_one.id)
    assert {:ok, reconnected} = TableServer.connect(room.id, user_one.id, make_ref())
    player = Enum.find(reconnected.players, &(&1.user_id == user_one.id))
    assert player.connected == true
    assert player.disconnect_deadline == nil
  end

  test "disconnecting one of multiple connections keeps player connected", %{
    room: room,
    user_one: user_one
  } do
    with_env("DISCONNECT_GRACE_SECONDS", "30")

    ref_one = make_ref()
    ref_two = make_ref()

    assert {:ok, _state_one} = join_connected(room, user_one, ref_one)
    assert {:ok, _state_two} = TableServer.connect(room.id, user_one.id, ref_two)

    assert :ok = TableServer.disconnect(room.id, user_one.id, ref_one)

    still_connected = TableServer.state(room.id, user_one.id)
    player = Enum.find(still_connected.players, &(&1.user_id == user_one.id))
    assert player.connected == true
    assert player.disconnect_deadline == nil

    assert :ok = TableServer.disconnect(room.id, user_one.id, ref_two)

    disconnected = TableServer.state(room.id, user_one.id)
    player = Enum.find(disconnected.players, &(&1.user_id == user_one.id))
    assert player.connected == false
    assert player.disconnect_deadline
  end

  test "disconnect grace expiry removes a waiting player", %{room: room, user_one: user_one} do
    with_env("DISCONNECT_GRACE_SECONDS", "0")

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert :ok = TableServer.disconnect(room.id, user_one.id)

    Process.sleep(30)

    state = TableServer.state(room.id, user_one.id)
    refute Enum.any?(state.players, &Map.get(&1, :is_me, false))
  end

  test "rate limits table chat", %{room: room, user_one: user_one} do
    with_env("CHAT_RATE_LIMIT_MS", "5000")

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert :ok = TableServer.chat(room.id, user_one.id, "hello")
    assert {:error, :rate_limited} = TableServer.chat(room.id, user_one.id, "too fast")
  end

  test "rejects empty and oversized chat messages", %{room: room, user_one: user_one} do
    with_env("MAX_CHAT_MESSAGE_LENGTH", "5")

    assert {:ok, _state_one} = join_connected(room, user_one)

    assert {:error, :empty_message} = TableServer.chat(room.id, user_one.id, "   ")
    assert {:error, :message_too_long} = TableServer.chat(room.id, user_one.id, "abcdef")
    assert :ok = TableServer.chat(room.id, user_one.id, "abcde")

    state = TableServer.state(room.id, user_one.id)
    assert [%{message: "abcde"} | _] = state.chat
  end

  test "rate limits repeated action attempts", %{
    room: room,
    user_one: user_one,
    user_two: user_two
  } do
    with_env("ACTION_RATE_LIMIT_MS", "5000")

    assert {:ok, _state_one} = join_connected(room, user_one)
    assert {:ok, _state_two} = join_connected(room, user_two)

    current_user_id = acting_user_id(room, [user_one, user_two])

    assert {:error, :invalid_action} = TableServer.act(room.id, current_user_id, "bogus", 0)
    assert {:error, :rate_limited} = TableServer.act(room.id, current_user_id, "fold", 0)
  end

  defp create_test_room(user, name, spectator_enabled) do
    Rooms.create_room(
      %{
        "name" => name,
        "max_players" => "2",
        "small_blind" => "5",
        "big_blind" => "10",
        "starting_chips" => "1000",
        "spectator_enabled" => to_string(spectator_enabled)
      },
      user.id
    )
  end
end
