defmodule MicuPoker.Poker.PotTest do
  use ExUnit.Case, async: true

  alias MicuPoker.Poker.{Card, Pot}

  defp c(rank, suit), do: %Card{rank: rank, suit: suit}

  defp player(id, username, seat, cards, contribution) do
    %{
      user_id: id,
      username: username,
      seat_number: seat,
      stack: 0,
      bet: 0,
      cards: cards,
      folded: false,
      all_in: true,
      in_hand: true,
      contribution_total: contribution
    }
  end

  test "settles a main pot and side pot by eligibility" do
    board = [
      c(2, :hearts),
      c(3, :diamonds),
      c(4, :spades),
      c(9, :clubs),
      c(13, :diamonds)
    ]

    short_stack = player(1, "Short", 1, [c(14, :hearts), c(5, :hearts)], 50)
    side_winner = player(2, "Side", 2, [c(13, :hearts), c(12, :clubs)], 100)
    side_loser = player(3, "Caller", 3, [c(12, :hearts), c(11, :clubs)], 100)

    settlement = Pot.settle_showdown([short_stack, side_winner, side_loser], board)

    assert Enum.map(settlement.pots, & &1.amount) == [150, 100]
    assert Enum.map(settlement.awards, &{&1.user_id, &1.amount}) == [{1, 150}, {2, 100}]

    stacks = Map.new(settlement.players, &{&1.user_id, &1.stack})
    assert stacks == %{1 => 150, 2 => 100, 3 => 0}
  end

  test "folded players fund pots but cannot win them" do
    board = [
      c(2, :hearts),
      c(7, :diamonds),
      c(8, :spades),
      c(9, :clubs),
      c(13, :diamonds)
    ]

    winner = player(1, "Winner", 1, [c(14, :hearts), c(14, :clubs)], 100)
    folded = %{player(2, "Folded", 2, [c(13, :hearts), c(13, :clubs)], 100) | folded: true}

    settlement = Pot.settle_showdown([winner, folded], board)

    assert Enum.map(settlement.awards, &{&1.user_id, &1.amount}) == [{1, 200}]
  end
end
