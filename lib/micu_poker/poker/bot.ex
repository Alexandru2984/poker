defmodule MicuPoker.Poker.Bot do
  @moduledoc """
  Decision engine for dealer-spawned practice AI bots.

  Bots operate strictly on their own hole cards, the public board, and the
  legal action set computed by `MicuPoker.Poker.Betting`. They never read
  other players' hole cards or the undealt deck.
  """

  alias MicuPoker.Poker.Analytics

  @profiles %{
    "tag" => %{label: "Tight-Aggressive", min_equity: 48.0, aggro_equity: 64.0},
    "lag" => %{label: "Loose-Aggressive", min_equity: 38.0, aggro_equity: 55.0},
    "station" => %{label: "Calling Station", min_equity: 34.0, aggro_equity: 76.0},
    "balanced" => %{label: "Balanced GTO", min_equity: 43.0, aggro_equity: 60.0}
  }

  def profiles, do: @profiles
  def profile_codes, do: Map.keys(@profiles)

  def normalize_profile(profile) when is_binary(profile) do
    code = profile |> String.trim() |> String.downcase()
    if Map.has_key?(@profiles, code), do: code, else: "balanced"
  end

  def normalize_profile(_profile), do: "balanced"

  @doc """
  Returns `{action, amount}` from `valid_actions` for `bot_player`.
  """
  def decide(state, bot_player) do
    valid = state.valid_actions_fun.(state, bot_player)
    actions = valid.actions
    call_amount = Map.get(valid, :call_amount, 0)
    big_blind = state.room.big_blind

    profile_code = normalize_profile(Map.get(bot_player, :bot_profile, "balanced"))
    profile = Map.fetch!(@profiles, profile_code)

    spot =
      Analytics.evaluate_spot(
        bot_player.cards,
        state.board,
        state.pot,
        call_amount,
        bot_player.stack,
        big_blind
      )

    choose_action(actions, valid, spot, profile, state, bot_player)
  end

  defp choose_action([], _valid, _spot, _profile, _state, _bot), do: {:fold, 0}

  defp choose_action(actions, valid, spot, profile, state, bot_player) do
    call_amount = Map.get(valid, :call_amount, 0)
    equity = spot.equity
    odds_pct = spot.pot_odds.percent

    cond do
      # Strong hand: bet or raise if legal
      equity >= profile.aggro_equity and :bet in actions ->
        amount = size_bet(valid, state.pot, state.room.big_blind)
        {:bet, amount}

      equity >= profile.aggro_equity and :raise in actions and
          call_amount <= div(bot_player.stack, 2) ->
        amount = size_raise(valid, state.pot)
        {:raise, amount}

      # Free check available
      :check in actions ->
        {:check, 0}

      # Profitable or playable call
      :call in actions and (equity >= odds_pct or equity >= profile.min_equity) and
          call_amount <= max(div(bot_player.stack * 2, 3), state.room.big_blind * 4) ->
        {:call, 0}

      # Short stack committed with decent hand
      :all_in in actions and equity >= profile.aggro_equity ->
        {:all_in, 0}

      :call in actions and equity >= profile.aggro_equity ->
        {:call, 0}

      :fold in actions ->
        {:fold, 0}

      true ->
        {hd(actions), 0}
    end
  end

  defp size_bet(valid, pot, big_blind) do
    min_bet = Map.get(valid, :min_bet, big_blind)
    max_bet = Map.get(valid, :max_total_bet, min_bet)
    target = max(div(pot * 2, 3), big_blind * 2)

    target |> max(min_bet) |> min(max_bet)
  end

  defp size_raise(valid, pot) do
    min_raise = Map.get(valid, :min_raise_to, 1)
    max_raise = Map.get(valid, :max_total_bet, min_raise)
    target = max(min_raise, pot)

    target |> max(min_raise) |> min(max_raise)
  end
end
