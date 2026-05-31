defmodule MicuPoker.Poker.DeckTest do
  use ExUnit.Case, async: true

  alias MicuPoker.Poker.{Card, Deck}

  test "deck has 52 unique cards" do
    deck = Deck.new()
    assert length(deck) == 52
    assert deck |> Enum.map(&Card.label/1) |> Enum.uniq() |> length() == 52
  end

  test "shuffle keeps a valid 52 card deck" do
    labels = Deck.shuffle() |> Enum.map(&Card.label/1)
    assert length(labels) == 52
    assert length(Enum.uniq(labels)) == 52
  end

  test "card public view includes poker symbols" do
    card = %Card{rank: 14, suit: :spades}

    assert Card.public(card).display == "A♠"
    assert Card.public(card).suit_symbol == "♠"
    assert Card.public(card).rank_label == "A"
  end
end
