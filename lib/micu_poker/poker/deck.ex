defmodule MicuPoker.Poker.Deck do
  @moduledoc """
  Secure 52-card deck helpers.
  """

  alias MicuPoker.Poker.Card

  def new do
    for suit <- Card.suits(), rank <- Card.ranks(), do: %Card{rank: rank, suit: suit}
  end

  def shuffle(deck \\ new()) do
    deck
    |> Enum.map(fn card -> {:crypto.strong_rand_bytes(16), card} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  def deal(deck, count) when count >= 0 do
    Enum.split(deck, count)
  end
end
