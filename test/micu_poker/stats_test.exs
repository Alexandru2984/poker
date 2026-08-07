defmodule MicuPoker.StatsTest do
  use MicuPoker.DataCase, async: true

  alias MicuPoker.{Accounts, Rooms, Stats}

  setup do
    {:ok, user} = Accounts.create_guest_user()
    {:ok, room} = Rooms.create_room(%{"name" => "Stats Table"}, user.id)

    %{user: user, room: room}
  end

  defp finished_hand(room, number) do
    {:ok, hand} = Rooms.create_hand(room.id, number)

    {:ok, hand} =
      Rooms.finish_hand(hand, %{
        pot_total: 100,
        winner_summary: %{winners: [%{username: "Someone", amount: 100, hand: "flush"}]},
        board_cards_sanitized: %{cards: ["AS", "KH", "2D", "7C", "9S"]}
      })

    hand
  end

  defp ledger(room, user, hand, delta, reason \\ "showdown") do
    {:ok, _result} =
      Rooms.record_ledger([
        %{
          user_id: user.id,
          room_id: room.id,
          hand_id: hand && hand.id,
          delta: delta,
          reason: reason
        }
      ])
  end

  describe "player_stats/1" do
    test "a player with no history reads as all zeroes", %{user: user} do
      stats = Stats.player_stats(user.id)

      assert stats.hands_played == 0
      assert stats.hands_won == 0
      assert stats.net_chips == 0
      assert stats.win_rate == 0.0
      assert stats.vpip == 0.0
    end

    test "wins and losses net out", %{user: user, room: room} do
      ledger(room, user, finished_hand(room, 1), 250)
      ledger(room, user, finished_hand(room, 2), -100)

      stats = Stats.player_stats(user.id)

      assert stats.net_chips == 150
      assert stats.hands_won == 1
      assert stats.biggest_pot == 250
    end

    test "rebuys are excluded from profit", %{user: user, room: room} do
      ledger(room, user, finished_hand(room, 1), -1000)
      Rooms.record_rebuy(room.id, user.id, 1000)

      stats = Stats.player_stats(user.id)

      # Buying more chips is not winning them.
      assert stats.net_chips == -1000
      assert stats.rebuys == 1
      assert stats.hands_won == 0
    end

    test "hands played counts distinct hands, not actions", %{user: user, room: room} do
      hand = finished_hand(room, 1)
      Rooms.record_action(hand.id, user.id, "call", 10, "preflop")
      Rooms.record_action(hand.id, user.id, "check", 0, "flop")
      Rooms.record_action(hand.id, user.id, "fold", 0, "turn")

      assert Stats.player_stats(user.id).hands_played == 1
    end

    test "VPIP counts only hands entered by choice", %{user: user, room: room} do
      voluntary = finished_hand(room, 1)
      Rooms.record_action(voluntary.id, user.id, "raise", 30, "preflop")

      free = finished_hand(room, 2)
      Rooms.record_action(free.id, user.id, "check", 0, "preflop")
      Rooms.record_action(free.id, user.id, "fold", 0, "flop")

      stats = Stats.player_stats(user.id)

      assert stats.hands_played == 2
      assert stats.vpip == 50.0
    end

    test "a timed-out fold is not voluntary money", %{user: user, room: room} do
      hand = finished_hand(room, 1)
      Rooms.record_action(hand.id, user.id, "timeout_fold", 0, "preflop")

      assert Stats.player_stats(user.id).vpip == 0.0
    end

    test "the win rate is a percentage of hands played", %{user: user, room: room} do
      for number <- 1..4 do
        hand = finished_hand(room, number)
        Rooms.record_action(hand.id, user.id, "call", 10, "preflop")
        ledger(room, user, hand, if(number == 1, do: 100, else: -10))
      end

      stats = Stats.player_stats(user.id)

      assert stats.hands_played == 4
      assert stats.hands_won == 1
      assert stats.win_rate == 25.0
    end
  end

  describe "leaderboard/1" do
    test "ranks players by net chips won", %{room: room} do
      {:ok, winner} = Accounts.create_guest_user()
      {:ok, loser} = Accounts.create_guest_user()
      hand = finished_hand(room, 1)

      ledger(room, winner, hand, 500)
      ledger(room, loser, hand, -500)

      [top | rest] = Stats.leaderboard()

      assert top.user_id == winner.id
      assert top.net_chips == 500
      assert Enum.any?(rest, &(&1.user_id == loser.id))
    end

    test "rebuys cannot inflate a ranking", %{room: room} do
      {:ok, honest} = Accounts.create_guest_user()
      {:ok, rebuyer} = Accounts.create_guest_user()
      hand = finished_hand(room, 1)

      ledger(room, honest, hand, 100)
      Rooms.record_rebuy(room.id, rebuyer.id, 100_000)

      leaderboard = Stats.leaderboard()

      assert hd(leaderboard).user_id == honest.id
      refute Enum.any?(leaderboard, &(&1.user_id == rebuyer.id))
    end

    test "honours the requested limit", %{room: room} do
      hand = finished_hand(room, 1)

      for _ <- 1..5 do
        {:ok, player} = Accounts.create_guest_user()
        ledger(room, player, hand, 10)
      end

      assert length(Stats.leaderboard(3)) == 3
    end
  end

  describe "recent_hands/2" do
    test "returns finished hands newest first", %{room: room} do
      for number <- 1..3, do: finished_hand(room, number)

      hands = Stats.recent_hands(room.id)

      assert Enum.map(hands, & &1.hand_number) == [3, 2, 1]
    end

    test "unfinished hands are not listed", %{room: room} do
      finished_hand(room, 1)
      {:ok, _in_progress} = Rooms.create_hand(room.id, 2)

      assert Enum.map(Stats.recent_hands(room.id), & &1.hand_number) == [1]
    end

    test "the board and winners are unwrapped for rendering", %{room: room} do
      finished_hand(room, 1)

      [hand] = Stats.recent_hands(room.id)

      assert hand.board == ["AS", "KH", "2D", "7C", "9S"]
      assert [%{"username" => "Someone", "amount" => 100}] = hand.winners
    end

    test "hole cards are never part of the history", %{room: room} do
      finished_hand(room, 1)

      encoded = room.id |> Stats.recent_hands() |> Jason.encode!()

      refute encoded =~ "hole"
      refute encoded =~ "user_id"
    end

    test "another room's hands are not included", %{room: room, user: user} do
      {:ok, other} = Rooms.create_room(%{"name" => "Other Stats Table"}, user.id)
      finished_hand(room, 1)
      finished_hand(other, 1)

      assert length(Stats.recent_hands(room.id)) == 1
    end
  end
end
