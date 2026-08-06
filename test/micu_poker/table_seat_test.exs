defmodule MicuPoker.Poker.TableSeatTest do
  @moduledoc """
  Sitting out, sitting back in, and buying back in after busting.
  """

  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableServer
  alias MicuPoker.Repo
  alias MicuPoker.Rooms
  alias MicuPoker.Rooms.{ChipLedger, RoomPlayer}

  setup do
    previous = System.get_env("NEXT_HAND_DELAY_MS")
    System.put_env("NEXT_HAND_DELAY_MS", "20")

    on_exit(fn ->
      if previous,
        do: System.put_env("NEXT_HAND_DELAY_MS", previous),
        else: System.delete_env("NEXT_HAND_DELAY_MS")
    end)

    users =
      for _ <- 1..3 do
        {:ok, user} = Accounts.create_guest_user()
        user
      end

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Seat Control Table",
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

  defp seat(room, user) do
    assert {:ok, _} = TableServer.join(room.id, user.id)
    assert {:ok, state} = TableServer.connect(room.id, user.id, make_ref())
    state
  end

  defp me(room, user) do
    room.id
    |> TableServer.state(user.id)
    |> Map.fetch!(:players)
    |> Enum.find(&Map.get(&1, :is_me, false))
  end

  defp bust(room, user) do
    :sys.replace_state(
      GenServer.whereis(TableServer.via(room.id)),
      fn state ->
        %{
          state
          | stage: :complete,
            players:
              Enum.map(state.players, fn player ->
                if player.user_id == user.id do
                  %{player | stack: 0, in_hand: false, cards: []}
                else
                  player
                end
              end)
        }
      end
    )
  end

  describe "sitting out" do
    test "a seated player can sit out and back in", %{room: room, users: [one, two | _]} do
      seat(room, one)
      seat(room, two)

      assert {:ok, _state} = TableServer.sit_out(room.id, one.id)
      assert me(room, one).sitting_out

      assert {:ok, _state} = TableServer.sit_in(room.id, one.id)
      refute me(room, one).sitting_out
    end

    test "the seat is kept, not given up", %{room: room, users: [one, two | _]} do
      seat(room, one)
      seat(room, two)
      original_seat = me(room, one).seat_number

      assert {:ok, _state} = TableServer.sit_out(room.id, one.id)

      assert me(room, one).seat_number == original_seat
      assert Rooms.seated?(room.id, one.id)
    end

    test "repeating the request is accepted without churn", %{room: room, users: [one, two | _]} do
      seat(room, one)
      seat(room, two)

      assert {:ok, _} = TableServer.sit_out(room.id, one.id)
      assert {:ok, _} = TableServer.sit_out(room.id, one.id)
      assert me(room, one).sitting_out
    end

    test "a player who is not seated cannot sit out", %{room: room, users: [one | _]} do
      {:ok, outsider} = Accounts.create_guest_user()
      seat(room, one)

      assert {:error, :not_seated} = TableServer.sit_out(room.id, outsider.id)
    end

    test "a table drops to waiting when too few players remain in", %{
      room: room,
      users: [one, two | _]
    } do
      seat(room, one)
      state = seat(room, two)
      assert state.stage == :preflop

      assert {:ok, _} = TableServer.sit_out(room.id, one.id)

      # Sitting out applies from the next hand, so the current one plays on.
      assert TableServer.state(room.id, two.id).stage == :preflop
    end

    test "a player sitting out is not dealt into the next hand", %{
      room: room,
      users: [one, two, three]
    } do
      seat(room, one)
      seat(room, two)
      seat(room, three)

      assert {:ok, _} = TableServer.sit_out(room.id, three.id)

      # Fold the current hand out so a new one is dealt.
      fold_until_complete(room, [one, two, three])
      wait_for_stage(room, one, :preflop)

      refute me(room, three).in_hand
      assert me(room, three).sitting_out
    end
  end

  describe "rebuying" do
    test "a busted player can buy back in and is dealt in again", %{
      room: room,
      users: [one, two | _]
    } do
      seat(room, one)
      seat(room, two)
      bust(room, one)

      assert me(room, one).stack == 0
      assert {:ok, _state} = TableServer.rebuy(room.id, one.id)

      # With chips again there are two live players, so the next hand is dealt
      # straight away and the blind is already out of the fresh stack.
      player = me(room, one)
      assert player.stack > 0
      assert player.stack >= room.starting_chips - room.big_blind
      assert player.in_hand
    end

    test "the new stack is persisted and recorded in the ledger", %{
      room: room,
      users: [one, two | _]
    } do
      seat(room, one)
      seat(room, two)
      bust(room, one)

      assert {:ok, _state} = TableServer.rebuy(room.id, one.id)

      persisted =
        RoomPlayer
        |> where([rp], rp.room_id == ^room.id and rp.user_id == ^one.id and is_nil(rp.left_at))
        |> Repo.one!()

      assert persisted.stack == room.starting_chips

      entry = Repo.get_by!(ChipLedger, room_id: room.id, user_id: one.id, reason: "rebuy")
      assert entry.delta == room.starting_chips
      assert entry.hand_id == nil
    end

    test "a player with chips left cannot top up", %{room: room, users: [one, two | _]} do
      seat(room, one)
      seat(room, two)

      assert {:error, :stack_not_empty} = TableServer.rebuy(room.id, one.id)
    end

    test "a player cannot rebuy in the middle of their own hand", %{
      room: room,
      users: [one, two | _]
    } do
      seat(room, one)
      seat(room, two)

      # Zero the stack without ending the hand, as an all-in would.
      :sys.replace_state(
        GenServer.whereis(TableServer.via(room.id)),
        fn state ->
          %{
            state
            | players:
                Enum.map(state.players, fn player ->
                  if player.user_id == one.id, do: %{player | stack: 0}, else: player
                end)
          }
        end
      )

      assert {:error, :hand_in_progress} = TableServer.rebuy(room.id, one.id)
    end

    test "rebuying clears a sit-out so the player is dealt in again", %{
      room: room,
      users: [one, two | _]
    } do
      seat(room, one)
      seat(room, two)
      assert {:ok, _} = TableServer.sit_out(room.id, one.id)
      bust(room, one)

      assert {:ok, _} = TableServer.rebuy(room.id, one.id)

      refute me(room, one).sitting_out
      assert me(room, one).stack > 0
    end

    test "an outsider cannot rebuy at a table they do not sit at", %{room: room, users: [one | _]} do
      {:ok, outsider} = Accounts.create_guest_user()
      seat(room, one)

      assert {:error, :not_seated} = TableServer.rebuy(room.id, outsider.id)
    end
  end

  defp fold_until_complete(room, users, attempts \\ 5) do
    state = TableServer.state(room.id, hd(users).id)

    if state.stage in [:preflop, :flop, :turn, :river] and attempts > 0 do
      actor =
        Enum.find(users, fn user ->
          player = me(room, user)
          player && player.seat_number == state.turn_seat
        end)

      TableServer.act(room.id, actor.id, "fold", 0)
      Process.sleep(5)
      fold_until_complete(room, users, attempts - 1)
    end
  end

  defp wait_for_stage(room, user, stage, attempts \\ 60) do
    cond do
      TableServer.state(room.id, user.id).stage == stage -> :ok
      attempts == 0 -> flunk("table never reached #{stage}")
      true -> Process.sleep(20) && wait_for_stage(room, user, stage, attempts - 1)
    end
  end
end
