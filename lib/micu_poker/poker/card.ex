defmodule MicuPoker.Poker.Card do
  @moduledoc """
  Card representation for Texas Hold'em.
  """

  @enforce_keys [:rank, :suit]
  defstruct [:rank, :suit]

  @type suit :: :clubs | :diamonds | :hearts | :spades
  @type t :: %__MODULE__{rank: 2..14, suit: suit()}

  @suits [:clubs, :diamonds, :hearts, :spades]
  @rank_labels %{
    14 => "A",
    13 => "K",
    12 => "Q",
    11 => "J",
    10 => "10",
    9 => "9",
    8 => "8",
    7 => "7",
    6 => "6",
    5 => "5",
    4 => "4",
    3 => "3",
    2 => "2"
  }
  @suit_labels %{clubs: "C", diamonds: "D", hearts: "H", spades: "S"}
  @suit_symbols %{clubs: "♣", diamonds: "♦", hearts: "♥", spades: "♠"}
  @suit_names %{clubs: "clubs", diamonds: "diamonds", hearts: "hearts", spades: "spades"}

  def suits, do: @suits
  def ranks, do: 2..14

  def label(%__MODULE__{rank: rank, suit: suit}) do
    "#{Map.fetch!(@rank_labels, rank)}#{Map.fetch!(@suit_labels, suit)}"
  end

  def display(%__MODULE__{rank: rank, suit: suit}) do
    "#{rank_label(rank)}#{suit_symbol(suit)}"
  end

  def rank_label(rank), do: Map.fetch!(@rank_labels, rank)
  def suit_symbol(suit), do: Map.fetch!(@suit_symbols, suit)

  def public(%__MODULE__{} = card) do
    %{
      rank: card.rank,
      rank_label: rank_label(card.rank),
      suit: card.suit,
      suit_name: Map.fetch!(@suit_names, card.suit),
      suit_symbol: suit_symbol(card.suit),
      label: label(card),
      display: display(card),
      color: color(card.suit)
    }
  end

  defp color(:diamonds), do: "red"
  defp color(:hearts), do: "red"
  defp color(_), do: "black"
end
