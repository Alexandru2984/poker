defmodule MicuPoker.Poker.TableActionOrderTest do
  @moduledoc """
  Action order, button rotation and uncalled-bet handling driven through the
  real table process.

  These behaviours are only observable across a whole hand, so the tests play
  hands out rather than poking at internal state.
  """

  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableServer
  alias MicuPoker.Rooms

  setup do
    # Hands are played back to back here with no human delay, so the per-player
    # action throttle has to be out of the way.
    put_env("NEXT_HAND_DELAY_MS", "10")
    put_env("ACTION_RATE_LIMIT_MS", "0")

    users =
      for _ <- 1..3 do
        {:ok, user} = Accounts.create_guest_user()
        user
      end

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Action Order Table",
          "max_players" => "3",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000"
        },
        hd(users).id
      )

    start_supervised!({TableServer, room.id})

    %{room: room, users: users}
  end

  defp put_env(name, value) do
    previous = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      if previous, do: System.put_env(name, previous), else: System.delete_env(name)
    end)
  end

  defp view(room, user), do: TableServer.state(room.id, user.id)

  defp own_player(view), do: Enum.find(view.players, &Map.get(&1, :is_me, false))

  defp seat_of(room, user), do: own_player(view(room, user)).seat_number

  defp user_on_turn(room, users) do
    turn_seat = view(room, hd(users)).turn_seat

    Enum.find(users, fn user ->
      player = own_player(view(room, user))
      player && player.seat_number == turn_seat
    end)
  end

  # Plays whichever of the listed actions is currently legal, in order.
  defp act_in_turn(room, users, preferences, amount \\ 0) do
    user = user_on_turn(room, users)
    refute is_nil(user), "no player is on turn"

    actions = view(room, user).valid_actions.actions
    action = Enum.find(preferences, &(&1 in actions))
    refute is_nil(action), "none of #{inspect(preferences)} are legal, got #{inspect(actions)}"

    assert :ok = TableServer.act(room.id, user.id, to_string(action), amount)
    user
  end

  defp seat_all(room, users) do
    [first, second, third] = users

    # A hand starts as soon as two players are connected, so the third seat
    # joins the heads-up hand and is dealt in from the following one.
    assert {:ok, _} = TableServer.join(room.id, first.id)
    assert {:ok, _} = TableServer.connect(room.id, first.id, make_ref())
    assert {:ok, _} = TableServer.join(room.id, second.id)
    assert {:ok, _} = TableServer.connect(room.id, second.id, make_ref())
    assert {:ok, _} = TableServer.join(room.id, third.id)
    assert {:ok, _} = TableServer.connect(room.id, third.id, make_ref())

    :ok
  end

  # Folds around until only one player is left, then waits for the deal.
  defp finish_hand_by_folding(room, users) do
    Enum.reduce_while(1..length(users), nil, fn _attempt, _acc ->
      if view(room, hd(users)).stage in [:preflop, :flop, :turn, :river] do
        act_in_turn(room, users, [:fold])
        {:cont, nil}
      else
        {:halt, nil}
      end
    end)

    wait_for_next_hand(room, users)
  end

  defp wait_for_next_hand(room, users, attempts \\ 60) do
    state = view(room, hd(users))

    cond do
      state.stage == :preflop -> state
      attempts == 0 -> flunk("the next hand never started, stage: #{inspect(state.stage)}")
      true -> Process.sleep(20) && wait_for_next_hand(room, users, attempts - 1)
    end
  end

  describe "action order" do
    test "preflop opens to the left of the big blind", %{room: room, users: users} do
      seat_all(room, users)
      state = finish_hand_by_folding(room, users)

      assert length(Enum.filter(state.players, & &1.in_hand)) == 3
      # Three-handed the seat left of the big blind wraps back to the button.
      assert state.turn_seat == state.dealer_seat
      refute state.turn_seat == state.big_blind_seat
      refute state.turn_seat == state.small_blind_seat
    end

    test "the flop opens with the first live player left of the button", %{
      room: room,
      users: users
    } do
      seat_all(room, users)
      finish_hand_by_folding(room, users)

      preflop = view(room, hd(users))
      assert length(Enum.filter(preflop.players, & &1.in_hand)) == 3
      dealer_seat = preflop.dealer_seat
      small_blind_seat = preflop.small_blind_seat

      # Button calls, small blind completes, big blind checks the option.
      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:call])
      last_preflop_actor = act_in_turn(room, users, [:check])

      flop = view(room, hd(users))
      assert flop.stage == :flop

      # The regression this guards: action used to continue from whoever spoke
      # last preflop instead of restarting left of the button.
      assert flop.turn_seat == small_blind_seat
      refute flop.turn_seat == seat_of(room, last_preflop_actor)
      refute flop.turn_seat == dealer_seat
    end

    test "each later street also reopens left of the button", %{room: room, users: users} do
      seat_all(room, users)
      finish_hand_by_folding(room, users)

      small_blind_seat = view(room, hd(users)).small_blind_seat

      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:check])

      for stage <- [:flop, :turn] do
        assert view(room, hd(users)).stage == stage
        assert view(room, hd(users)).turn_seat == small_blind_seat

        act_in_turn(room, users, [:check])
        act_in_turn(room, users, [:check])
        act_in_turn(room, users, [:check])
      end

      assert view(room, hd(users)).stage == :river
      assert view(room, hd(users)).turn_seat == small_blind_seat
    end
  end

  describe "button rotation" do
    test "the button moves one occupied seat per hand", %{room: room, users: users} do
      seat_all(room, users)

      first = wait_for_next_hand(room, users)
      seats = users |> Enum.map(&seat_of(room, &1)) |> Enum.sort()

      finish_hand_by_folding(room, users)
      second = view(room, hd(users))

      finish_hand_by_folding(room, users)
      third = view(room, hd(users))

      assert second.dealer_seat == next_seat(seats, first.dealer_seat)
      assert third.dealer_seat == next_seat(seats, second.dealer_seat)
    end

    test "the blinds follow the button", %{room: room, users: users} do
      seat_all(room, users)
      finish_hand_by_folding(room, users)

      state = view(room, hd(users))
      seats = users |> Enum.map(&seat_of(room, &1)) |> Enum.sort()

      assert state.small_blind_seat == next_seat(seats, state.dealer_seat)
      assert state.big_blind_seat == next_seat(seats, state.small_blind_seat)
    end
  end

  defp next_seat(seats, seat) do
    Enum.find(seats, &(&1 > seat)) || hd(seats)
  end

  describe "uncalled bets" do
    test "a bet nobody calls comes back instead of inflating the pot", %{
      room: room,
      users: users
    } do
      seat_all(room, users)
      finish_hand_by_folding(room, users)

      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:check])

      assert view(room, hd(users)).stage == :flop
      pot_before = view(room, hd(users)).pot

      bettor = act_in_turn(room, users, [:bet], 200)
      stack_after_bet = own_player(view(room, bettor)).stack

      act_in_turn(room, users, [:fold])
      act_in_turn(room, users, [:fold])

      final = view(room, bettor)
      winner = own_player(final)

      # The 200 was never matched, so it is handed back and only the pot that
      # existed before the bet is actually won.
      assert winner.stack == stack_after_bet + 200 + pot_before
    end

    test "chips are conserved across a hand that ends on an uncalled bet", %{
      room: room,
      users: users
    } do
      seat_all(room, users)
      finish_hand_by_folding(room, users)

      total_before = table_chips(room, users)

      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:call])
      act_in_turn(room, users, [:check])
      act_in_turn(room, users, [:bet], 150)
      act_in_turn(room, users, [:fold])
      act_in_turn(room, users, [:fold])

      state = view(room, hd(users))

      assert state.pot == 0
      assert table_chips(room, users) == total_before
    end
  end

  defp table_chips(room, users) do
    state = view(room, hd(users))
    Enum.sum(Enum.map(state.players, & &1.stack)) + state.pot
  end
end
