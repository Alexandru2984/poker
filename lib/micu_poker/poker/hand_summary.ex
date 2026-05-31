defmodule MicuPoker.Poker.HandSummary do
  @moduledoc """
  Human-facing hand descriptions for table UI.
  """

  alias MicuPoker.Poker.{Card, HandEvaluator}

  @rank_words %{
    14 => "Aces",
    13 => "Kings",
    12 => "Queens",
    11 => "Jacks",
    10 => "Tens",
    9 => "Nines",
    8 => "Eights",
    7 => "Sevens",
    6 => "Sixes",
    5 => "Fives",
    4 => "Fours",
    3 => "Threes",
    2 => "Twos"
  }

  @rank_singular %{
    14 => "Ace",
    13 => "King",
    12 => "Queen",
    11 => "Jack",
    10 => "Ten",
    9 => "Nine",
    8 => "Eight",
    7 => "Seven",
    6 => "Six",
    5 => "Five",
    4 => "Four",
    3 => "Three",
    2 => "Two"
  }

  def summarize(hole_cards, board_cards \\ []) do
    cards = hole_cards ++ board_cards

    cond do
      hole_cards == [] ->
        %{title: "Waiting", detail: "No cards in this hand.", rank: nil, cards: []}

      length(cards) >= 5 ->
        made_hand(cards)

      length(hole_cards) == 2 ->
        preflop(hole_cards)

      true ->
        %{
          title: "Cards dealt",
          detail: joined_cards(hole_cards),
          rank: nil,
          cards: Enum.map(hole_cards, &Card.public/1)
        }
    end
  end

  def human_rank(:royal_flush), do: "Royal flush"
  def human_rank(:straight_flush), do: "Straight flush"
  def human_rank(:four_of_a_kind), do: "Four of a kind"
  def human_rank(:full_house), do: "Full house"
  def human_rank(:flush), do: "Flush"
  def human_rank(:straight), do: "Straight"
  def human_rank(:three_of_a_kind), do: "Three of a kind"
  def human_rank(:two_pair), do: "Two pair"
  def human_rank(:one_pair), do: "One pair"
  def human_rank(:high_card), do: "High card"
  def human_rank(other), do: other |> to_string() |> String.replace("_", " ")

  def board_texture(board_cards) do
    cond do
      length(board_cards) < 3 ->
        %{title: "Preflop", detail: "Waiting for the flop."}

      true ->
        %{
          title: board_title(board_cards),
          detail:
            [
              paired_board_detail(board_cards),
              flush_detail(board_cards),
              straight_detail(board_cards)
            ]
            |> Enum.reject(&is_nil/1)
            |> case do
              [] -> "Dry board."
              details -> Enum.join(details, " ")
            end
        }
    end
  end

  defp made_hand(cards) do
    eval = HandEvaluator.evaluate(cards)
    best = Enum.sort_by(eval.cards, & &1.rank, :desc)

    %{
      title: human_rank(eval.name),
      detail: made_detail(eval),
      rank: eval.rank,
      score: eval.score,
      cards: Enum.map(best, &Card.public/1)
    }
  end

  defp made_detail(%{name: :royal_flush}), do: "A-K-Q-J-10 suited."
  defp made_detail(%{name: :straight_flush, kickers: [high]}), do: "#{rank_name(high)} high."
  defp made_detail(%{name: :four_of_a_kind, kickers: [rank | _]}), do: "#{rank_word(rank)}."

  defp made_detail(%{name: :full_house, kickers: [trip, pair]}),
    do: "#{rank_word(trip)} full of #{String.downcase(rank_word(pair))}."

  defp made_detail(%{name: :flush, kickers: [high | _]}), do: "#{rank_name(high)} high flush."
  defp made_detail(%{name: :straight, kickers: [high]}), do: "#{rank_name(high)} high straight."

  defp made_detail(%{name: :three_of_a_kind, kickers: [rank | _]}),
    do: "Three #{String.downcase(rank_word(rank))}."

  defp made_detail(%{name: :two_pair, kickers: [high, low | _]}),
    do: "#{rank_word(high)} and #{String.downcase(rank_word(low))}."

  defp made_detail(%{name: :one_pair, kickers: [rank | _]}),
    do: "Pair of #{String.downcase(rank_word(rank))}."

  defp made_detail(%{name: :high_card, kickers: [high | _]}), do: "#{rank_name(high)} high."

  defp preflop([left, right] = cards) do
    suited? = left.suit == right.suit
    gap = abs(left.rank - right.rank)
    high = max(left.rank, right.rank)

    cond do
      left.rank == right.rank ->
        %{
          title: "Pocket pair",
          detail: "Pair of #{String.downcase(rank_word(left.rank))}.",
          rank: 1,
          cards: Enum.map(cards, &Card.public/1)
        }

      suited? and gap == 1 ->
        %{
          title: "Suited connector",
          detail: "#{joined_cards(cards)}.",
          rank: 0,
          cards: Enum.map(cards, &Card.public/1)
        }

      suited? ->
        %{
          title: "Suited hand",
          detail: "#{rank_name(high)} high suited.",
          rank: 0,
          cards: Enum.map(cards, &Card.public/1)
        }

      gap == 1 ->
        %{
          title: "Connector",
          detail: "#{joined_cards(cards)}.",
          rank: 0,
          cards: Enum.map(cards, &Card.public/1)
        }

      true ->
        %{
          title: "High card",
          detail: "#{rank_name(high)} high.",
          rank: 0,
          cards: Enum.map(cards, &Card.public/1)
        }
    end
  end

  defp board_title(board_cards) do
    case length(board_cards) do
      3 -> "Flop texture"
      4 -> "Turn texture"
      5 -> "River texture"
      _ -> "Board texture"
    end
  end

  defp paired_board_detail(cards) do
    counts = cards |> Enum.map(& &1.rank) |> Enum.frequencies() |> Map.values()

    cond do
      3 in counts -> "Trips on board."
      2 in counts -> "Paired board."
      true -> nil
    end
  end

  defp flush_detail(cards) do
    max_suit_count =
      cards |> Enum.map(& &1.suit) |> Enum.frequencies() |> Map.values() |> Enum.max()

    cond do
      max_suit_count >= 5 -> "Flush possible."
      max_suit_count == 4 -> "Four to a flush."
      max_suit_count == 3 -> "Flush draw possible."
      true -> nil
    end
  end

  defp straight_detail(cards) do
    ranks = cards |> Enum.map(& &1.rank) |> Enum.uniq()
    wheel_ranks = if 14 in ranks, do: [1 | ranks], else: ranks

    has_four_connected? =
      1..10
      |> Enum.any?(fn start ->
        needed = MapSet.new(start..(start + 3))
        MapSet.subset?(needed, MapSet.new(wheel_ranks))
      end)

    if has_four_connected?, do: "Straight draw possible."
  end

  defp joined_cards(cards), do: cards |> Enum.map(&Card.display/1) |> Enum.join(" ")
  defp rank_word(rank), do: Map.fetch!(@rank_words, rank)
  defp rank_name(rank), do: Map.fetch!(@rank_singular, rank)
end
