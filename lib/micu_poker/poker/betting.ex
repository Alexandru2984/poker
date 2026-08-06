defmodule MicuPoker.Poker.Betting do
  @moduledoc """
  Pure Texas Hold'em betting-line rules.

  The *line* is the part of a betting round that decides what a player is
  allowed to do: the amount everyone must match (`current_bet`), the size of the
  last full raise (`min_raise`), who has already acted at the current amount
  (`acted`), and who has lost the right to raise because the only aggression
  since their turn was an all-in smaller than a full raise (`raise_closed`).

  Every function takes and returns a plain map holding those four keys, so
  `MicuPoker.Poker.TableServer` can pass its whole state through and keep the
  fields flat, while the rules stay testable without a table, a deck, or a
  database.
  """

  @type line :: %{
          required(:current_bet) => non_neg_integer(),
          required(:min_raise) => pos_integer(),
          required(:acted) => MapSet.t(),
          required(:raise_closed) => MapSet.t(),
          optional(any()) => any()
        }

  @doc """
  A line with no money in it, ready for a new betting round.
  """
  def fresh(big_blind) do
    %{
      current_bet: 0,
      min_raise: big_blind,
      acted: MapSet.new(),
      raise_closed: MapSet.new()
    }
  end

  @doc """
  Resets `line` for the start of a new street, keeping unrelated keys intact.
  """
  def open_round(line, big_blind), do: Map.merge(line, fresh(big_blind))

  @doc """
  What `player` still owes to stay in the hand.
  """
  def call_amount(line, player), do: max(line.current_bet - player.bet, 0)

  @doc """
  The smallest total a legal raise may move the line to.
  """
  def min_raise_to(line), do: line.current_bet + line.min_raise

  @doc """
  Whether `user_id` may still raise, or is restricted to calling and folding.
  """
  def can_raise?(line, user_id), do: not MapSet.member?(line.raise_closed, user_id)

  @doc """
  Records that `user_id` has acted at the current amount.
  """
  def mark_acted(line, user_id), do: %{line | acted: MapSet.put(line.acted, user_id)}

  @doc """
  Opens the betting for `amount`. Only legal when the line is unopened.
  """
  def bet(line, user_id, amount) do
    Map.merge(line, %{
      current_bet: amount,
      min_raise: amount,
      acted: MapSet.new([user_id]),
      raise_closed: MapSet.new()
    })
  end

  @doc """
  Raises the line to `amount`, reopening the round for everybody else.
  """
  def raise_to(line, user_id, amount) do
    Map.merge(line, %{
      current_bet: amount,
      min_raise: max(amount - line.current_bet, line.min_raise),
      acted: MapSet.new([user_id]),
      raise_closed: MapSet.new()
    })
  end

  @doc """
  Applies an all-in of `total` chips to the line.

  Three outcomes:

    * `total` at or below the current bet is a call for less and moves nothing.
    * A full raise moves the line and gives everyone a fresh decision.
    * A short all-in moves the line, so opponents must still cover the
      difference, but players who already acted may only call or fold. Letting
      a short all-in reopen the betting is one of the classic ways an engine
      lets a player manufacture extra raises out of a tiny stack.
  """
  def all_in(line, user_id, total) do
    raise_by = total - line.current_bet

    cond do
      raise_by <= 0 ->
        line

      raise_by >= line.min_raise ->
        Map.merge(line, %{
          current_bet: total,
          min_raise: raise_by,
          acted: MapSet.new([user_id]),
          raise_closed: MapSet.new()
        })

      true ->
        Map.merge(line, %{
          current_bet: total,
          raise_closed: MapSet.union(line.raise_closed, line.acted)
        })
    end
  end

  @doc """
  Whether the round is closed: every player who can still act has matched the
  line and had a turn at the current amount.
  """
  def round_complete?(line, players) do
    players
    |> Enum.filter(&(&1.in_hand && !&1.folded && !&1.all_in))
    |> Enum.all?(&(&1.bet == line.current_bet && MapSet.member?(line.acted, &1.user_id)))
  end

  @doc """
  The actions `player` may take, with the amounts the client needs to render
  them. Callers are responsible for checking that it is actually the player's
  turn; this only decides what is legal given the line and their stack.
  """
  def valid_actions(line, player, big_blind) do
    call = call_amount(line, player)
    max_total = player.bet + player.stack
    raise_reopened? = can_raise?(line, player.user_id)

    actions =
      [:fold]
      |> put_if(call == 0, :check)
      |> put_if(call > 0 and player.stack > 0, :call)
      |> put_if(line.current_bet == 0 and player.stack >= big_blind, :bet)
      |> put_if(
        line.current_bet > 0 and raise_reopened? and max_total >= min_raise_to(line),
        :raise
      )
      |> put_if(player.stack > 0, :all_in)
      |> Enum.reverse()

    %{
      actions: actions,
      call_amount: min(call, player.stack),
      min_bet: big_blind,
      min_raise_to: min_raise_to(line),
      max_total_bet: max_total,
      raise_reopened: raise_reopened?
    }
  end

  defp put_if(actions, true, action), do: [action | actions]
  defp put_if(actions, false, _action), do: actions
end
