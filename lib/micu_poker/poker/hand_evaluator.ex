defmodule MicuPoker.Poker.HandEvaluator do
  @moduledoc """
  Evaluates the best 5-card poker hand from 5 to 7 cards.
  """

  @rank_names %{
    9 => :royal_flush,
    8 => :straight_flush,
    7 => :four_of_a_kind,
    6 => :full_house,
    5 => :flush,
    4 => :straight,
    3 => :three_of_a_kind,
    2 => :two_pair,
    1 => :one_pair,
    0 => :high_card
  }

  def evaluate(cards) when length(cards) in 5..7 do
    cards
    |> combinations(5)
    |> Enum.map(&score_five/1)
    |> Enum.max_by(fn %{score: score} -> score end)
  end

  def compare(left_cards, right_cards) do
    compare_scores(evaluate(left_cards).score, evaluate(right_cards).score)
  end

  def compare_scores(left, right) do
    cond do
      left > right -> :gt
      left < right -> :lt
      true -> :eq
    end
  end

  def rank_name(%{rank: rank}), do: Map.fetch!(@rank_names, rank)
  def rank_name(rank) when is_integer(rank), do: Map.fetch!(@rank_names, rank)

  defp score_five(cards) do
    ranks = cards |> Enum.map(& &1.rank) |> Enum.sort(:desc)

    groups =
      ranks
      |> Enum.frequencies()
      |> Enum.group_by(fn {_rank, count} -> count end, fn {rank, _count} -> rank end)

    flush? = cards |> Enum.map(& &1.suit) |> Enum.uniq() |> length() == 1
    straight_high = straight_high(ranks)

    {rank, kickers} =
      cond do
        flush? and straight_high == 14 -> {9, [14]}
        flush? and straight_high -> {8, [straight_high]}
        groups[4] -> {7, [Enum.max(groups[4]), highest_except(ranks, groups[4])]}
        groups[3] && (length(groups[3]) > 1 || groups[2]) -> full_house(groups)
        flush? -> {5, ranks}
        straight_high -> {4, [straight_high]}
        groups[3] -> {3, [Enum.max(groups[3]) | take_except(ranks, groups[3], 2)]}
        groups[2] && length(groups[2]) >= 2 -> two_pair(ranks, groups[2])
        groups[2] -> {1, [Enum.max(groups[2]) | take_except(ranks, groups[2], 3)]}
        true -> {0, ranks}
      end

    %{
      rank: rank,
      name: Map.fetch!(@rank_names, rank),
      kickers: kickers,
      score: [rank | kickers],
      cards: cards
    }
  end

  defp full_house(groups) do
    trips = Enum.sort(groups[3], :desc)
    trip = hd(trips)
    pair = trips |> tl() |> Kernel.++(groups[2] || []) |> Enum.max()
    {6, [trip, pair]}
  end

  defp two_pair(ranks, pairs) do
    [high, low | _] = Enum.sort(pairs, :desc)
    {2, [high, low, highest_except(ranks, [high, low])]}
  end

  defp highest_except(ranks, except), do: hd(take_except(ranks, except, 1))

  defp take_except(ranks, except, count) do
    except = MapSet.new(except)
    ranks |> Enum.reject(&MapSet.member?(except, &1)) |> Enum.take(count)
  end

  defp straight_high(ranks) do
    unique = ranks |> Enum.uniq() |> Enum.sort(:desc)
    wheel = if Enum.all?([14, 5, 4, 3, 2], &(&1 in unique)), do: 5

    regular =
      unique
      |> Enum.chunk_every(5, 1, :discard)
      |> Enum.find_value(fn chunk ->
        if hd(chunk) - List.last(chunk) == 4, do: hd(chunk)
      end)

    regular || wheel
  end

  defp combinations(_list, 0), do: [[]]
  defp combinations([], _count), do: []

  defp combinations([head | tail], count) do
    for(rest <- combinations(tail, count - 1), do: [head | rest]) ++ combinations(tail, count)
  end
end
