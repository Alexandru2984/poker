defmodule MicuPoker.Stats do
  @moduledoc """
  Read-only aggregates over the hand history and chip ledger.

  Everything here is derived from rows the table process already writes while
  hands play out, so no additional bookkeeping runs on the hot path.

  Rebuy ledger entries are chips entering a table from outside a hand. They are
  excluded from profit so a player cannot climb the leaderboard by busting and
  buying in repeatedly.
  """

  import Ecto.Query

  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo
  alias MicuPoker.Rooms.{ChipLedger, Hand, HandAction}

  @hand_reasons ["showdown", "uncontested"]

  @doc """
  Career numbers for one player.
  """
  def player_stats(user_id) do
    ledger = ledger_summary(user_id)
    actions = action_summary(user_id)

    hands_played = actions.hands_played

    %{
      hands_played: hands_played,
      hands_won: ledger.hands_won,
      net_chips: ledger.net,
      biggest_pot: ledger.biggest_win,
      rebuys: ledger.rebuys,
      win_rate: percentage(ledger.hands_won, hands_played),
      vpip: percentage(actions.voluntary_hands, hands_played)
    }
  end

  @doc """
  Top players by net chips won, excluding chips brought in by rebuying.
  """
  def leaderboard(limit \\ 20) do
    from(entry in ChipLedger,
      join: user in User,
      on: user.id == entry.user_id,
      where: entry.reason in @hand_reasons,
      group_by: [user.id, user.username, user.is_guest],
      order_by: [desc: sum(entry.delta)],
      limit: ^limit,
      select: %{
        user_id: user.id,
        username: user.username,
        is_guest: user.is_guest,
        net_chips: sum(entry.delta),
        hands_won: filter(count(entry.id), entry.delta > 0),
        hands_recorded: count(entry.id)
      }
    )
    |> Repo.all()
  end

  @doc """
  The most recent finished hands at a table, newest first.

  Only the public-safe summary the table already persisted is returned: winner
  names, amounts and the board. Hole cards are never stored.
  """
  def recent_hands(room_id, limit \\ 20) do
    from(hand in Hand,
      where: hand.room_id == ^room_id and not is_nil(hand.ended_at),
      order_by: [desc: hand.hand_number],
      limit: ^limit,
      select: %{
        hand_number: hand.hand_number,
        ended_at: hand.ended_at,
        pot_total: hand.pot_total,
        winners: hand.winner_summary,
        board: hand.board_cards_sanitized
      }
    )
    |> Repo.all()
    |> Enum.map(&normalize_hand/1)
  end

  defp normalize_hand(hand) do
    %{
      hand
      | winners: Map.get(hand.winners || %{}, "winners", []),
        board: Map.get(hand.board || %{}, "cards", [])
    }
  end

  defp ledger_summary(user_id) do
    result =
      from(entry in ChipLedger,
        where: entry.user_id == ^user_id,
        select: %{
          net: coalesce(filter(sum(entry.delta), entry.reason in @hand_reasons), 0),
          hands_won:
            coalesce(
              filter(count(entry.id), entry.delta > 0 and entry.reason in @hand_reasons),
              0
            ),
          biggest_win: coalesce(filter(max(entry.delta), entry.reason in @hand_reasons), 0),
          rebuys: coalesce(filter(count(entry.id), entry.reason == "rebuy"), 0)
        }
      )
      |> Repo.one()

    result || %{net: 0, hands_won: 0, biggest_win: 0, rebuys: 0}
  end

  # VPIP counts hands where the player put money in by choice. Blinds are posted
  # automatically and a check costs nothing, so neither counts as voluntary.
  defp action_summary(user_id) do
    result =
      from(action in HandAction,
        where: action.user_id == ^user_id and not is_nil(action.hand_id),
        select: %{
          hands_played: count(action.hand_id, :distinct),
          voluntary_hands:
            filter(
              count(action.hand_id, :distinct),
              action.action in ["call", "bet", "raise", "all_in"]
            )
        }
      )
      |> Repo.one()

    result || %{hands_played: 0, voluntary_hands: 0}
  end

  defp percentage(_part, 0), do: 0.0
  defp percentage(_part, nil), do: 0.0

  defp percentage(part, whole) do
    Float.round(part / whole * 100, 1)
  end
end
