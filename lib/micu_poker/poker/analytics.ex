defmodule MicuPoker.Poker.Analytics do
  @moduledoc """
  Pure-Elixir poker simulator analytics: pot odds, stack-to-pot ratio (SPR),
  stack depth in big blinds, preflop hand strength tiers, and exact postflop
  next-street improvement outs.

  Uses only the viewer's own hole cards and the public board cards so no
  information about opponents' hidden cards or the undealt deck is ever leaked.
  """

  alias MicuPoker.Poker.{Card, Deck, HandEvaluator, HandSummary}

  @doc """
  Computes pot odds for calling `call_amount` into `pot`.
  """
  def pot_odds(pot, call_amount) when is_integer(pot) and is_integer(call_amount) do
    cond do
      call_amount <= 0 ->
        %{percent: 0.0, ratio: "Free check", call_amount: 0}

      pot + call_amount <= 0 ->
        %{percent: 0.0, ratio: "0:1", call_amount: call_amount}

      true ->
        total_pot = pot + call_amount
        percent = Float.round(call_amount / total_pot * 100.0, 1)
        ratio = Float.round(pot / call_amount * 1.0, 1)
        %{percent: percent, ratio: "#{ratio}:1", call_amount: call_amount}
    end
  end

  def pot_odds(_pot, _call_amount), do: %{percent: 0.0, ratio: "Free check", call_amount: 0}

  @doc """
  Computes the Stack-to-Pot Ratio (SPR).
  """
  def spr(stack, pot) when is_integer(stack) and is_integer(pot) and pot > 0 do
    Float.round(stack / pot * 1.0, 1)
  end

  def spr(_stack, _pot), do: nil

  @doc """
  Computes stack depth in big blinds.
  """
  def stack_bb(stack, big_blind)
      when is_integer(stack) and is_integer(big_blind) and big_blind > 0 do
    Float.round(stack / big_blind * 1.0, 1)
  end

  def stack_bb(_stack, _big_blind), do: 0.0

  @doc """
  Generates the 13x13 (169-cell) Texas Hold'em preflop starting hand matrix.
  Above diagonal = suited, diagonal = pocket pairs, below diagonal = offsuit.
  """
  def preflop_matrix do
    ranks = Enum.to_list(14..2//-1)

    for r1 <- ranks do
      for r2 <- ranks do
        high = max(r1, r2)
        low = min(r1, r2)

        {kind, label, sample_cards} =
          cond do
            r1 == r2 ->
              {:pair, "#{Card.rank_label(r1)}#{Card.rank_label(r2)}",
               [%Card{rank: r1, suit: :spades}, %Card{rank: r2, suit: :hearts}]}

            r1 > r2 ->
              {:suited, "#{Card.rank_label(high)}#{Card.rank_label(low)}s",
               [%Card{rank: high, suit: :spades}, %Card{rank: low, suit: :spades}]}

            true ->
              {:offsuit, "#{Card.rank_label(high)}#{Card.rank_label(low)}o",
               [%Card{rank: high, suit: :spades}, %Card{rank: low, suit: :hearts}]}
          end

        strength = preflop_strength(sample_cards)

        %{
          r1: r1,
          r2: r2,
          kind: kind,
          label: label,
          equity: strength.equity,
          tier: strength.tier,
          tier_class: "tier-" <> String.downcase(strength.tier)
        }
      end
    end
  end

  @doc """
  Builds the complete simulator HUD analytics for a player's current spot.
  """
  def evaluate_spot(hole_cards, board_cards, pot, call_amount, stack, big_blind) do
    odds = pot_odds(pot, call_amount)
    spr_val = spr(stack, pot)
    bb_val = stack_bb(stack, big_blind)

    strength =
      cond do
        length(hole_cards) < 2 ->
          %{tier: "Waiting", equity: 0.0, outs: 0, outs_detail: "Waiting for deal"}

        board_cards == [] ->
          preflop_strength(hole_cards)

        true ->
          postflop_strength(hole_cards, board_cards)
      end

    advice = recommendation(strength.equity, odds.percent, call_amount)

    %{
      pot_odds: odds,
      spr: spr_val,
      stack_bb: bb_val,
      tier: strength.tier,
      equity: strength.equity,
      outs: strength.outs,
      outs_detail: strength.outs_detail,
      advice: advice
    }
  end

  defp preflop_strength([c1, c2]) do
    high = max(c1.rank, c2.rank)
    low = min(c1.rank, c2.rank)
    pair? = c1.rank == c2.rank
    suited? = c1.suit == c2.suit
    gap = high - low

    base =
      cond do
        pair? and high >= 10 -> 78.0 + (high - 10) * 2.0
        pair? -> 54.0 + (high - 2) * 2.5
        high == 14 and low >= 10 -> 63.0 + (low - 10) * 2.0
        high >= 12 and low >= 10 -> 56.0 + (high - 12) * 1.5
        true -> 36.0 + high * 1.2 + low * 0.6
      end

    suited_bonus = if suited? and not pair?, do: 4.0, else: 0.0

    gap_penalty =
      cond do
        pair? -> 0.0
        gap == 1 -> -1.0
        gap == 2 -> -3.0
        gap == 3 -> -5.0
        true -> -8.0
      end

    equity =
      (base + suited_bonus + gap_penalty)
      |> max(28.0)
      |> min(85.0)
      |> Float.round(1)

    tier =
      cond do
        equity >= 72.0 -> "Premium"
        equity >= 61.0 -> "Strong"
        equity >= 51.0 -> "Playable"
        equity >= 43.0 -> "Speculative"
        true -> "Marginal"
      end

    %{
      tier: tier,
      equity: equity,
      outs: 0,
      outs_detail: "Preflop starting hand"
    }
  end

  defp postflop_strength(hole_cards, board_cards) do
    known = hole_cards ++ board_cards
    current_eval = HandEvaluator.evaluate(known)
    {outs, improving_ranks} = count_improvement_outs(known, current_eval)

    # Rule of 4 and 2 combined with current made-hand baseline equity
    street_multiplier = if length(board_cards) == 3, do: 4.0, else: 2.2
    draw_equity = min(outs * street_multiplier, 58.0)

    made_baseline =
      case current_eval.rank do
        9 -> 99.0
        8 -> 97.0
        7 -> 95.0
        6 -> 90.0
        5 -> 84.0
        4 -> 79.0
        3 -> 72.0
        2 -> 64.0
        1 -> 48.0 + List.first(current_eval.kickers, 2) * 0.8
        _ -> 24.0 + List.first(current_eval.kickers, 2) * 0.7
      end

    equity =
      max(made_baseline, min(made_baseline * 0.45 + draw_equity, 98.0))
      |> Float.round(1)

    tier =
      cond do
        current_eval.rank >= 4 -> "Monster"
        current_eval.rank >= 2 -> "Strong Made"
        current_eval.rank == 1 and outs >= 5 -> "Pair + Draw"
        current_eval.rank == 1 -> "Made Pair"
        outs >= 8 -> "Strong Draw"
        outs >= 4 -> "Draw"
        true -> "Air / High Card"
      end

    outs_detail =
      cond do
        length(board_cards) >= 5 ->
          "Final river board"

        outs == 0 ->
          "Currently #{HandSummary.human_rank(current_eval.name)}"

        true ->
          targets =
            improving_ranks
            |> Enum.map(&HandSummary.human_rank/1)
            |> Enum.take(2)
            |> Enum.join(" / ")

          "#{outs} outs to #{targets}"
      end

    %{
      tier: tier,
      equity: equity,
      outs: outs,
      outs_detail: outs_detail
    }
  end

  defp count_improvement_outs(known_cards, current_eval) do
    if length(known_cards) >= 7 do
      {0, []}
    else
      known_set = MapSet.new(known_cards)

      unseen =
        Deck.new()
        |> Enum.reject(&MapSet.member?(known_set, &1))

      improvements =
        Enum.reduce(unseen, [], fn %Card{} = next_card, acc ->
          next_eval = HandEvaluator.evaluate([next_card | known_cards])

          if next_eval.rank > current_eval.rank do
            [next_eval.name | acc]
          else
            acc
          end
        end)

      outs_count = length(improvements)

      top_targets =
        improvements
        |> Enum.frequencies()
        |> Enum.sort_by(fn {_name, count} -> count end, :desc)
        |> Enum.map(&elem(&1, 0))

      {outs_count, top_targets}
    end
  end

  defp recommendation(_equity, _pot_odds_pct, 0), do: "Free check or bet for value"

  defp recommendation(equity, pot_odds_pct, _call_amount) do
    margin = equity - pot_odds_pct

    cond do
      margin >= 18.0 -> "+EV Value (Strong edge)"
      margin >= 3.0 -> "+EV Call (Profitable odds)"
      margin >= -5.0 -> "Close Spot (Implied odds)"
      true -> "-EV Call (Price too high)"
    end
  end
end
