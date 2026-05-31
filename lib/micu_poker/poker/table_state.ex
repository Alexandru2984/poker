defmodule MicuPoker.Poker.TableState do
  @moduledoc false

  alias MicuPoker.Poker.{Card, HandSummary}

  def sanitize(state, viewer_id \\ nil) do
    %{
      room: room_public(state.room),
      stage: state.stage,
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
      valid_actions: valid_actions_for_viewer(state, viewer_id),
      play_money_only: true,
      side_pots_supported: true
    }
  end

  defp room_public(room) do
    %{
      id: room.id,
      name: room.name,
      max_players: room.max_players,
      small_blind: room.small_blind,
      big_blind: room.big_blind,
      starting_chips: room.starting_chips,
      status: room.status,
      spectator_enabled: room.spectator_enabled
    }
  end

  defp player_public(player, state, viewer_id) do
    show_cards? =
      player.user_id == viewer_id or
        state.stage in [:showdown, :complete] or
        (state.stage == :waiting and player.cards == [])

    %{
      user_id: player.user_id,
      username: player.username,
      seat_number: player.seat_number,
      stack: player.stack,
      bet: player.bet,
      folded: player.folded,
      all_in: player.all_in,
      in_hand: player.in_hand,
      connected: player.connected,
      disconnect_deadline: player.disconnect_deadline,
      hand_summary:
        if(show_cards?, do: HandSummary.summarize(player.cards, state.board), else: nil),
      cards:
        if(show_cards?,
          do: Enum.map(player.cards, &Card.public/1),
          else: Enum.map(player.cards, fn _ -> %{hidden: true} end)
        )
    }
  end

  defp valid_actions_for_viewer(_state, nil), do: %{actions: []}

  defp valid_actions_for_viewer(state, viewer_id) do
    case Enum.find(state.players, &(&1.user_id == viewer_id)) do
      nil -> %{actions: []}
      player -> state.valid_actions_fun.(state, player)
    end
  end
end
