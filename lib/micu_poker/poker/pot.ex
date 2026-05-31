defmodule MicuPoker.Poker.Pot do
  @moduledoc """
  Main-pot and side-pot settlement for showdown.
  """

  alias MicuPoker.Poker.HandEvaluator

  def settle_showdown(players, board) do
    ranked =
      players
      |> Enum.filter(&(&1.in_hand && !&1.folded))
      |> Map.new(fn player -> {player.user_id, HandEvaluator.evaluate(board ++ player.cards)} end)

    pots = side_pots(players)

    awards =
      Enum.flat_map(pots, fn pot ->
        contenders = Enum.filter(pot.eligible, &Map.has_key?(ranked, &1.user_id))

        case contenders do
          [] ->
            []

          _ ->
            best_score =
              contenders
              |> Enum.map(&ranked[&1.user_id].score)
              |> Enum.max()

            winners =
              contenders
              |> Enum.filter(&(ranked[&1.user_id].score == best_score))
              |> Enum.sort_by(& &1.seat_number)

            share = div(pot.amount, length(winners))
            remainder = rem(pot.amount, length(winners))

            winners
            |> Enum.with_index()
            |> Enum.map(fn {winner, index} ->
              %{
                user_id: winner.user_id,
                username: winner.username,
                seat_number: winner.seat_number,
                amount: share + if(index == 0, do: remainder, else: 0),
                eval: ranked[winner.user_id]
              }
            end)
        end
      end)

    award_totals =
      awards
      |> Enum.group_by(& &1.user_id)
      |> Map.new(fn {user_id, entries} -> {user_id, Enum.sum(Enum.map(entries, & &1.amount))} end)

    settled_players =
      Enum.map(players, fn player ->
        %{
          player
          | stack: player.stack + Map.get(award_totals, player.user_id, 0),
            bet: 0,
            contribution_total: 0
        }
      end)

    %{players: settled_players, awards: awards, pots: pots}
  end

  def side_pots(players) do
    thresholds =
      players
      |> Enum.map(&Map.get(&1, :contribution_total, 0))
      |> Enum.filter(&(&1 > 0))
      |> Enum.uniq()
      |> Enum.sort()

    {pots, _previous} =
      Enum.map_reduce(thresholds, 0, fn threshold, previous ->
        eligible = Enum.filter(players, &(Map.get(&1, :contribution_total, 0) >= threshold))
        amount = (threshold - previous) * length(eligible)
        {%{amount: amount, eligible: eligible}, threshold}
      end)

    Enum.reject(pots, &(&1.amount <= 0))
  end
end
