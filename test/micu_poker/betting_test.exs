defmodule MicuPoker.Poker.BettingTest do
  use ExUnit.Case, async: true

  alias MicuPoker.Poker.Betting

  @big_blind 10

  defp player(attrs \\ %{}) do
    Map.merge(
      %{
        user_id: 1,
        bet: 0,
        stack: 1000,
        in_hand: true,
        folded: false,
        all_in: false
      },
      attrs
    )
  end

  defp line(attrs \\ %{}), do: Map.merge(Betting.fresh(@big_blind), attrs)

  describe "opening the betting" do
    test "an unopened line offers check and bet, never call" do
      %{actions: actions} = Betting.valid_actions(line(), player(), @big_blind)

      assert :check in actions
      assert :bet in actions
      refute :call in actions
      refute :raise in actions
    end

    test "a facing bet offers call and raise, never check" do
      %{actions: actions} =
        Betting.valid_actions(line(%{current_bet: 50, min_raise: 50}), player(), @big_blind)

      assert :call in actions
      assert :raise in actions
      refute :check in actions
      refute :bet in actions
    end

    test "a bet sets the minimum for the next raise" do
      updated = Betting.bet(line(), 1, 50)

      assert updated.current_bet == 50
      assert updated.min_raise == 50
      assert Betting.min_raise_to(updated) == 100
    end

    test "a player too short to open the minimum bet can still move all-in" do
      %{actions: actions} = Betting.valid_actions(line(), player(%{stack: 4}), @big_blind)

      refute :bet in actions
      assert :all_in in actions
    end
  end

  describe "raising" do
    test "a raise reopens the round for everyone else" do
      updated =
        line(%{current_bet: 50, min_raise: 50, acted: MapSet.new([1, 2, 3])})
        |> Betting.raise_to(2, 150)

      assert updated.current_bet == 150
      assert updated.min_raise == 100
      assert MapSet.to_list(updated.acted) == [2]
    end

    test "the minimum raise never shrinks below the previous one" do
      updated = line(%{current_bet: 100, min_raise: 80}) |> Betting.raise_to(2, 150)

      assert updated.min_raise == 80
    end

    test "raise is withheld from a stack that cannot cover the minimum" do
      short = player(%{stack: 60, bet: 0})

      %{actions: actions} =
        Betting.valid_actions(line(%{current_bet: 50, min_raise: 50}), short, @big_blind)

      refute :raise in actions
      assert :call in actions
      assert :all_in in actions
    end
  end

  describe "short all-in and the min-raise rule" do
    test "an all-in below the current bet does not move the line" do
      original = line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1, 2])})
      updated = Betting.all_in(original, 3, 40)

      assert updated.current_bet == 100
      assert updated.acted == original.acted
    end

    test "an all-in that is a full raise reopens the round" do
      updated =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1, 2])})
        |> Betting.all_in(3, 200)

      assert updated.current_bet == 200
      assert updated.min_raise == 100
      assert MapSet.to_list(updated.acted) == [3]
      assert Enum.empty?(updated.raise_closed)
    end

    test "a short all-in raises the amount owed but does not reopen the round" do
      updated =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1, 2])})
        |> Betting.all_in(3, 140)

      assert updated.current_bet == 140
      # Players who already acted still owe the extra 40 ...
      assert updated.acted == MapSet.new([1, 2])
      # ... but they have lost the right to raise over it.
      refute Betting.can_raise?(updated, 1)
      refute Betting.can_raise?(updated, 2)
    end

    test "a player restricted by a short all-in is offered call and fold only" do
      restricted =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1])})
        |> Betting.all_in(3, 140)

      %{actions: actions} =
        Betting.valid_actions(restricted, player(%{user_id: 1, bet: 100}), @big_blind)

      assert :call in actions
      assert :fold in actions
      assert :all_in in actions
      refute :raise in actions
    end

    test "a player who had not yet acted may still raise over a short all-in" do
      restricted =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1])})
        |> Betting.all_in(3, 140)

      %{actions: actions} =
        Betting.valid_actions(restricted, player(%{user_id: 9, bet: 0}), @big_blind)

      assert :raise in actions
      assert Betting.can_raise?(restricted, 9)
    end

    test "a later full raise restores the right to raise for everyone" do
      reopened =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1, 2])})
        |> Betting.all_in(3, 140)
        |> Betting.raise_to(9, 300)

      assert Betting.can_raise?(reopened, 1)
      assert Betting.can_raise?(reopened, 2)
    end

    test "two short all-ins in a row keep everyone restricted" do
      restricted =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1])})
        |> Betting.all_in(2, 130)
        |> Betting.mark_acted(4)
        |> Betting.all_in(3, 150)

      refute Betting.can_raise?(restricted, 1)
      refute Betting.can_raise?(restricted, 4)
      assert restricted.current_bet == 150
    end
  end

  describe "round_complete?/2" do
    test "an untouched round is not complete" do
      players = [player(%{user_id: 1}), player(%{user_id: 2})]

      refute Betting.round_complete?(line(), players)
    end

    test "a round is complete once everyone matched and acted" do
      line = line(%{current_bet: 50, acted: MapSet.new([1, 2])})
      players = [player(%{user_id: 1, bet: 50}), player(%{user_id: 2, bet: 50})]

      assert Betting.round_complete?(line, players)
    end

    test "a player who matched but has not acted still owes a turn" do
      # This is the big blind's option: their posted blind already matches the
      # line, but they have not had a chance to raise.
      line = line(%{current_bet: 10, acted: MapSet.new([1])})
      players = [player(%{user_id: 1, bet: 10}), player(%{user_id: 2, bet: 10})]

      refute Betting.round_complete?(line, players)
    end

    test "folded and all-in players are not waited on" do
      line = line(%{current_bet: 50, acted: MapSet.new([1])})

      players = [
        player(%{user_id: 1, bet: 50}),
        player(%{user_id: 2, bet: 20, folded: true}),
        player(%{user_id: 3, bet: 30, all_in: true})
      ]

      assert Betting.round_complete?(line, players)
    end

    test "a short all-in leaves the round incomplete until the extra is covered" do
      line =
        line(%{current_bet: 100, min_raise: 100, acted: MapSet.new([1, 2])})
        |> Betting.all_in(3, 140)

      players = [
        player(%{user_id: 1, bet: 100}),
        player(%{user_id: 2, bet: 100}),
        player(%{user_id: 3, bet: 140, all_in: true})
      ]

      refute Betting.round_complete?(line, players)
    end
  end

  describe "open_round/2" do
    test "clears the line but keeps unrelated state" do
      opened =
        line(%{current_bet: 250, min_raise: 100, acted: MapSet.new([1, 2])})
        |> Map.put(:pot, 500)
        |> Betting.all_in(3, 260)
        |> Betting.open_round(@big_blind)

      assert opened.current_bet == 0
      assert opened.min_raise == @big_blind
      assert Enum.empty?(opened.acted)
      assert Enum.empty?(opened.raise_closed)
      assert opened.pot == 500
    end
  end

  describe "call_amount/2" do
    test "is the difference between the line and what the player already put in" do
      assert Betting.call_amount(line(%{current_bet: 100}), player(%{bet: 40})) == 60
    end

    test "never goes negative" do
      assert Betting.call_amount(line(%{current_bet: 40}), player(%{bet: 100})) == 0
    end

    test "is capped at the player's stack in the rendered actions" do
      %{call_amount: call_amount} =
        Betting.valid_actions(line(%{current_bet: 500}), player(%{stack: 120}), @big_blind)

      assert call_amount == 120
    end
  end
end
