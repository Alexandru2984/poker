defmodule MicuPoker.Poker.TableState do
  @moduledoc false

  alias MicuPoker.Poker.{Analytics, Card, HandSummary}
  alias MicuPoker.Rooms
  alias MicuPoker.Rooms.Room

  def sanitize(state, viewer_id \\ nil) do
    valid_actions = valid_actions_for_viewer(state, viewer_id)

    %{
      room: room_public(state.room),
      stage: state.stage,
      paused: Map.get(state, :paused, false),
      is_dealer: Rooms.dealer?(state.room, viewer_id),
      ante: Map.get(state, :ante, 0),
      blind_level: Map.get(state, :blind_level, 1),
      blind_interval_minutes: Map.get(state, :blind_interval_minutes, 0),
      next_blind_level_at: Map.get(state, :next_blind_level_at, nil),
      hand_number: state.hand_number,
      board: Enum.map(state.board, &Card.public/1),
      board_summary: HandSummary.board_texture(state.board),
      pot: state.pot,
      current_bet: state.current_bet,
      min_raise: state.min_raise,
      dealer_seat: state.dealer_seat,
      small_blind_seat: state.small_blind_seat,
      big_blind_seat: state.big_blind_seat,
      turn_seat: state.turn_seat,
      action_deadline: state.action_deadline,
      players: Enum.map(state.players, &player_public(&1, state, viewer_id)),
      log: Enum.take(state.log, 80),
      chat: Enum.take(state.chat, 40),
      valid_actions: valid_actions,
      analytics: analytics_for_viewer(state, viewer_id, valid_actions),
      play_money_only: true,
      side_pots_supported: true
    }
  end

  defp room_public(room) do
    currency = Map.get(room, :currency) || "CHIPS"

    %{
      id: room.id,
      name: room.name,
      max_players: room.max_players,
      small_blind: room.small_blind,
      big_blind: room.big_blind,
      starting_chips: room.starting_chips,
      currency: currency,
      currency_info: Room.currency_info(currency),
      status: room.status,
      spectator_enabled: room.spectator_enabled
    }
  end

  defp player_public(player, state, viewer_id) do
    is_me? = player.user_id == viewer_id

    show_cards? =
      is_me? or
        Map.get(player, :revealed_cards, false) or
        (state.stage == :showdown and player.in_hand and not player.folded) or
        (state.stage == :waiting and player.cards == [])

    player
    |> public_player_fields(show_cards?, state.board)
    |> maybe_put_user_id(player.user_id, is_me?)
    |> Map.put(:is_me, is_me?)
    |> Map.put(:is_dealer, Rooms.dealer?(state.room, player.user_id))
  end

  defp public_player_fields(player, show_cards?, board) do
    %{
      username: player.username,
      seat_number: player.seat_number,
      stack: player.stack,
      bet: player.bet,
      folded: player.folded,
      all_in: player.all_in,
      in_hand: player.in_hand,
      connected: player.connected,
      sitting_out: Map.get(player, :sitting_out, false),
      is_bot: Map.get(player, :is_bot, false),
      bot_profile: Map.get(player, :bot_profile, nil),
      revealed_cards: Map.get(player, :revealed_cards, false),
      time_bank_used: Map.get(player, :time_bank_used, false),
      reaction: Map.get(player, :reaction, nil),
      disconnect_deadline: player.disconnect_deadline,
      hand_summary: if(show_cards?, do: HandSummary.summarize(player.cards, board), else: nil),
      cards: public_cards(player.cards, show_cards?)
    }
  end

  defp public_cards(cards, true), do: Enum.map(cards, &Card.public/1)
  defp public_cards(cards, false), do: Enum.map(cards, fn _ -> %{hidden: true} end)

  defp maybe_put_user_id(fields, user_id, true), do: Map.put(fields, :user_id, user_id)
  defp maybe_put_user_id(fields, _user_id, false), do: fields

  defp valid_actions_for_viewer(_state, nil), do: %{actions: []}

  defp valid_actions_for_viewer(state, viewer_id) do
    case Enum.find(state.players, &(&1.user_id == viewer_id)) do
      nil -> %{actions: []}
      player -> state.valid_actions_fun.(state, player)
    end
  end

  defp analytics_for_viewer(_state, nil, _valid_actions), do: nil

  defp analytics_for_viewer(state, viewer_id, valid_actions) do
    case Enum.find(state.players, &(&1.user_id == viewer_id)) do
      nil ->
        nil

      player ->
        call_amount =
          Map.get(valid_actions, :call_amount, max(state.current_bet - player.bet, 0))

        Analytics.evaluate_spot(
          player.cards,
          state.board,
          state.pot,
          call_amount,
          player.stack,
          state.room.big_blind
        )
    end
  end
end
