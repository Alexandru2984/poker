defmodule MicuPoker.Poker.HandEvaluatorTest do
  use ExUnit.Case, async: true

  alias MicuPoker.Poker.{Card, HandEvaluator}

  defp c(rank, suit), do: %Card{rank: rank, suit: suit}

  test "recognizes ranking categories" do
    assert HandEvaluator.evaluate([
             c(14, :hearts),
             c(13, :hearts),
             c(12, :hearts),
             c(11, :hearts),
             c(10, :hearts)
           ]).name == :royal_flush

    assert HandEvaluator.evaluate([
             c(9, :clubs),
             c(8, :clubs),
             c(7, :clubs),
             c(6, :clubs),
             c(5, :clubs)
           ]).name == :straight_flush

    assert HandEvaluator.evaluate([
             c(4, :clubs),
             c(4, :diamonds),
             c(4, :hearts),
             c(4, :spades),
             c(12, :clubs)
           ]).name == :four_of_a_kind

    assert HandEvaluator.evaluate([
             c(10, :clubs),
             c(10, :diamonds),
             c(10, :hearts),
             c(2, :spades),
             c(2, :clubs)
           ]).name == :full_house

    assert HandEvaluator.evaluate([
             c(14, :spades),
             c(9, :spades),
             c(7, :spades),
             c(4, :spades),
             c(2, :spades)
           ]).name == :flush

    assert HandEvaluator.evaluate([
             c(6, :clubs),
             c(5, :diamonds),
             c(4, :hearts),
             c(3, :spades),
             c(2, :clubs)
           ]).name == :straight

    assert HandEvaluator.evaluate([
             c(8, :clubs),
             c(8, :diamonds),
             c(8, :hearts),
             c(13, :spades),
             c(2, :clubs)
           ]).name == :three_of_a_kind

    assert HandEvaluator.evaluate([
             c(11, :clubs),
             c(11, :diamonds),
             c(3, :hearts),
             c(3, :spades),
             c(14, :clubs)
           ]).name == :two_pair

    assert HandEvaluator.evaluate([
             c(14, :clubs),
             c(14, :diamonds),
             c(9, :hearts),
             c(5, :spades),
             c(2, :clubs)
           ]).name == :one_pair

    assert HandEvaluator.evaluate([
             c(14, :clubs),
             c(12, :diamonds),
             c(9, :hearts),
             c(5, :spades),
             c(2, :clubs)
           ]).name == :high_card
  end

  test "compares winners" do
    straight = [c(6, :clubs), c(5, :diamonds), c(4, :hearts), c(3, :spades), c(2, :clubs)]
    trips = [c(8, :clubs), c(8, :diamonds), c(8, :hearts), c(13, :spades), c(2, :clubs)]

    assert HandEvaluator.compare(straight, trips) == :gt
  end
end
