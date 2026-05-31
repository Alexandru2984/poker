defmodule MicuPoker.Poker.HandSummaryTest do
  use ExUnit.Case, async: true

  alias MicuPoker.Poker.{Card, HandSummary}

  defp c(rank, suit), do: %Card{rank: rank, suit: suit}

  test "summarizes preflop pocket pairs and suited connectors" do
    assert HandSummary.summarize([c(14, :spades), c(14, :hearts)]).title == "Pocket pair"
    assert HandSummary.summarize([c(10, :hearts), c(9, :hearts)]).title == "Suited connector"
  end

  test "summarizes made poker hands after board cards" do
    summary =
      HandSummary.summarize(
        [c(14, :hearts), c(13, :hearts)],
        [c(12, :hearts), c(11, :hearts), c(10, :hearts), c(2, :clubs), c(3, :spades)]
      )

    assert summary.title == "Royal flush"
    assert summary.detail == "A-K-Q-J-10 suited."
    assert length(summary.cards) == 5
  end

  test "describes board texture" do
    texture =
      HandSummary.board_texture([
        c(14, :hearts),
        c(14, :clubs),
        c(9, :hearts),
        c(2, :hearts)
      ])

    assert texture.title == "Turn texture"
    assert texture.detail =~ "Paired board"
    assert texture.detail =~ "Flush draw possible"
  end
end
