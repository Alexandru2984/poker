defmodule MicuPokerWeb.TableLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Rooms
  alias MicuPoker.Stats
  alias MicuPokerWeb.TableLayout

  @impl true
  def mount(%{"id" => id}, session, socket) do
    with {:ok, room} <- Rooms.fetch_room(id),
         :ok <- authorize_room(socket, room, session),
         {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
      join_table(socket, room)
    else
      {:error, :locked} ->
        {:ok, push_navigate(socket, to: ~p"/rooms/#{id}/unlock")}

      _error ->
        {:ok,
         socket
         |> put_flash(:error, "Table was not found.")
         |> push_navigate(to: ~p"/lobby")}
    end
  end

  # A private table is entered through the password prompt, which records the
  # grant in the session. The creator never needs their own password.
  defp authorize_room(socket, room, session) do
    unlocked = session["unlocked_rooms"] || session[:unlocked_rooms] || []

    cond do
      not Rooms.protected?(room) -> :ok
      room.created_by == socket.assigns.current_user.id -> :ok
      is_list(unlocked) and room.id in unlocked -> :ok
      true -> {:error, :locked}
    end
  end

  defp join_table(socket, room) do
    case TableServer.join(room.id, socket.assigns.current_user.id) do
      {:ok, table} ->
        mount_table(socket, room, table)

      {:spectator, table} ->
        mount_table(socket, room, table)

      {:error, :room_full} ->
        {:ok,
         socket
         |> put_flash(:error, "Table is full and spectators are disabled.")
         |> push_navigate(to: ~p"/lobby")}

      {:error, reason} ->
        {:ok,
         socket
         |> put_flash(:error, "Could not join table: #{reason}")
         |> push_navigate(to: ~p"/lobby")}
    end
  end

  defp mount_table(socket, room, table) do
    connection_ref =
      if connected?(socket) and
           Enum.any?(table.players, &Map.get(&1, :is_me, false)) do
        make_ref()
      end

    table =
      if connection_ref do
        case TableServer.connect(room.id, socket.assigns.current_user.id, connection_ref) do
          {:ok, connected_table} -> connected_table
          {:error, _reason} -> table
        end
      else
        table
      end

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MicuPoker.PubSub, "table:#{room.id}")
      Process.send_after(self(), :tick, 1_000)
    end

    {:ok,
     socket
     |> assign(:page_title, room.name)
     |> assign(:room, room)
     |> assign(:room_id, room.id)
     |> assign(:connection_ref, connection_ref)
     |> assign(:invite_url, MicuPokerWeb.Endpoint.url() <> ~p"/rooms/#{room.id}")
     |> assign(:now, DateTime.utc_now(:second))
     |> assign(:panel, "chat")
     |> assign(:bb_view, false)
     |> assign(:currencies, MicuPoker.Rooms.Room.currencies())
     |> assign(:recent_hands, [])
     |> assign(:expanded_hand_id, nil)
     |> assign(:expanded_hand_actions, [])
     |> assign(:pre_action, nil)
     |> assign(:pre_action_bet, 0)
     |> assign(:chat_message, "")
     |> put_table(table)}
  end

  # Everything derived from the table view is recomputed in one place, so the
  # seat layout and the bet range can never drift from the state they describe.
  defp put_table(socket, table) do
    viewer_seat =
      case Enum.find(table.players, &Map.get(&1, :is_me, false)) do
        nil -> nil
        player -> player.seat_number
      end

    socket =
      socket
      |> assign(:table, table)
      |> assign(:seats, TableLayout.seats(table, viewer_seat))
      |> assign(:bet_presets, TableLayout.bet_presets(table))
      |> assign(:bet_amount, clamp_bet_amount(socket.assigns[:bet_amount], table, table.room))

    maybe_execute_pre_action(socket, table)
  end

  defp maybe_execute_pre_action(socket, table) do
    pre = socket.assigns[:pre_action]
    user = socket.assigns[:current_user]

    cond do
      is_nil(pre) or is_nil(user) ->
        socket

      table.stage not in [:preflop, :flop, :turn, :river] ->
        socket |> assign(:pre_action, nil) |> assign(:pre_action_bet, 0)

      my_turn?(table, user.id) ->
        valid = table.valid_actions.actions
        locked_bet = socket.assigns[:pre_action_bet] || 0
        socket = socket |> assign(:pre_action, nil) |> assign(:pre_action_bet, 0)

        auto_action =
          case pre do
            "check_fold" ->
              if :check in valid, do: "check", else: "fold"

            "check" ->
              if :check in valid, do: "check", else: nil

            "call" ->
              cond do
                :check in valid -> "check"
                :call in valid and table.current_bet <= locked_bet -> "call"
                true -> nil
              end

            _ ->
              nil
          end

        if auto_action do
          case TableServer.act(socket.assigns.room_id, user.id, auto_action, 0) do
            :ok ->
              case TableServer.state(socket.assigns.room_id, user.id) do
                nil -> socket
                updated -> put_table(socket, updated)
              end

            {:error, _} ->
              socket
          end
        else
          socket
        end

      true ->
        socket
    end
  end

  @impl true
  def handle_event("act", %{"action" => action} = params, socket) do
    amount = Map.get(params, "amount", socket.assigns.bet_amount)

    case TableServer.act(socket.assigns.room_id, socket.assigns.current_user.id, action, amount) do
      :ok ->
        {:noreply, refresh_table(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Action rejected: #{human_error(reason)}")}
    end
  end

  def handle_event("bet_amount", %{"amount" => amount}, socket) do
    amount = clamp_bet_amount(amount, socket.assigns.table, socket.assigns.room)
    {:noreply, assign(socket, :bet_amount, amount)}
  end

  def handle_event("panel", %{"panel" => panel}, socket)
      when panel in ~w(chat log hands info dealer) do
    # History is only queried when the tab is actually opened, so the page load
    # and every table broadcast stay off the database.
    socket =
      if panel == "hands" do
        assign(socket, :recent_hands, Stats.recent_hands(socket.assigns.room_id, 15))
      else
        socket
      end

    {:noreply, assign(socket, :panel, panel)}
  end

  def handle_event("panel", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_bb_view", _params, socket) do
    {:noreply, assign(socket, :bb_view, not socket.assigns.bb_view)}
  end

  def handle_event("pre_action", %{"mode" => mode}, socket)
      when mode in ~w(check_fold check call clear) do
    if mode == "clear" or socket.assigns.pre_action == mode do
      {:noreply, socket |> assign(:pre_action, nil) |> assign(:pre_action_bet, 0)}
    else
      {:noreply,
       socket
       |> assign(:pre_action, mode)
       |> assign(:pre_action_bet, socket.assigns.table.current_bet)}
    end
  end

  def handle_event("dealer_double_blinds", _params, socket) do
    room = socket.assigns.table.room
    new_sb = min(room.small_blind * 2, 1000)
    new_bb = min(max(room.big_blind * 2, new_sb * 2), 2000)
    new_buyin = max(room.starting_chips, new_bb * 20) |> min(100_000)

    settings = %{
      "small_blind" => to_string(new_sb),
      "big_blind" => to_string(new_bb),
      "starting_chips" => to_string(new_buyin),
      "currency" => room.currency
    }

    case TableServer.dealer_update_table(
           socket.assigns.room_id,
           socket.assigns.current_user.id,
           settings
         ) do
      {:ok, table} ->
        {:noreply,
         socket
         |> assign(:room, Rooms.get_room!(socket.assigns.room_id))
         |> put_table(table)
         |> put_flash(:info, "Blinds escalated to #{new_sb}/#{new_bb}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_set_ante", %{"ante" => ante}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_set_ante(room_id, user_id, ante) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Table ante updated to #{table.ante}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_set_blind_timer", %{"minutes" => minutes}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_set_blind_timer(room_id, user_id, minutes) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Sit & Go blind level timer updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("time_bank", _params, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.use_time_bank(room_id, user_id) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "+20s Time Bank activated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("inspect_hand", %{"hand-id" => hand_id_str}, socket) do
    case Integer.parse(to_string(hand_id_str)) do
      {hand_id, ""} when hand_id > 0 ->
        if socket.assigns.expanded_hand_id == hand_id do
          {:noreply,
           socket
           |> assign(:expanded_hand_id, nil)
           |> assign(:expanded_hand_actions, [])}
        else
          actions = Stats.hand_actions(socket.assigns.room_id, hand_id)

          {:noreply,
           socket
           |> assign(:expanded_hand_id, hand_id)
           |> assign(:expanded_hand_actions, actions)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("dealer_grant", %{"seat" => seat, "amount" => amount}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_grant_chips(room_id, user_id, seat, amount) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Fictional funds granted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_set_stack", %{"dealer" => %{"seat" => seat, "stack" => stack}}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_set_stack(room_id, user_id, seat, stack) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Player stack updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_reset_stacks", _params, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_reset_stacks(room_id, user_id) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "All player stacks reset to starting buy-in.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_update_table", %{"table_settings" => settings}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_update_table(room_id, user_id, settings) do
      {:ok, table} ->
        {:noreply,
         socket
         |> assign(:room, Rooms.get_room!(room_id))
         |> put_table(table)
         |> put_flash(:info, "Table currency & stakes updated.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_toggle_pause", _params, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_toggle_pause(room_id, user_id) do
      {:ok, table} ->
        {:noreply, put_table(socket, table)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_transfer", %{"seat" => seat}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_transfer(room_id, user_id, seat) do
      {:ok, table} ->
        {:noreply,
         socket
         |> assign(:room, Rooms.get_room!(room_id))
         |> put_table(table)
         |> put_flash(:info, "Dealer privileges transferred.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_kick_seat", %{"seat" => seat}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_kick_seat(room_id, user_id, seat) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Seat cleared by dealer.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_add_bot", %{"profile" => profile}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_add_bot(room_id, user_id, profile) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Practice AI bot added to the table.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("dealer_remove_bots", _params, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.dealer_remove_bots(room_id, user_id) do
      {:ok, table} ->
        {:noreply,
         socket
         |> put_table(table)
         |> put_flash(:info, "Practice AI bots removed.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Dealer action failed: #{human_error(reason)}")}
    end
  end

  def handle_event("show_cards", _params, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.show_cards(room_id, user_id) do
      {:ok, table} ->
        {:noreply, put_table(socket, table)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("switch_seat", %{"seat" => seat}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.switch_seat(room_id, user_id, seat) do
      {:ok, table} ->
        {:noreply, put_table(socket, table)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("react", %{"code" => code}, socket) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    case TableServer.react(room_id, user_id, code) do
      {:ok, table} ->
        {:noreply, put_table(socket, table)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("seat", %{"seat" => command}, socket)
      when command in ~w(sit_out sit_in rebuy show_cards) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.current_user.id

    result =
      case command do
        "sit_out" -> TableServer.sit_out(room_id, user_id)
        "sit_in" -> TableServer.sit_in(room_id, user_id)
        "rebuy" -> TableServer.rebuy(room_id, user_id)
        "show_cards" -> TableServer.show_cards(room_id, user_id)
      end

    case result do
      {:ok, table} -> {:noreply, put_table(socket, table)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, human_error(reason))}
    end
  end

  def handle_event("seat", _params, socket), do: {:noreply, socket}

  def handle_event("chat", %{"chat" => %{"message" => message}}, socket) do
    case TableServer.chat(socket.assigns.room_id, socket.assigns.current_user.id, message) do
      :ok ->
        {:noreply, assign(socket, :chat_message, "")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Chat rejected: #{human_error(reason)}")}
    end
  end

  @impl true
  def handle_info({:table_state, _table}, socket) do
    {:noreply, refresh_table(socket)}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, :now, DateTime.utc_now(:second))}
  end

  # The table process can be restarting or already shut down. Keep rendering the
  # last known view rather than crashing the player's LiveView.
  defp refresh_table(socket) do
    case TableServer.state(socket.assigns.room_id, socket.assigns.current_user.id) do
      nil -> socket
      table -> put_table(socket, table)
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:room_id] && socket.assigns[:current_user] &&
         socket.assigns[:connection_ref] do
      TableServer.disconnect(
        socket.assigns.room_id,
        socket.assigns.current_user.id,
        socket.assigns.connection_ref
      )
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp action?(table, action), do: action in table.valid_actions.actions

  defp current_player(table, _user_id), do: Enum.find(table.players, &Map.get(&1, :is_me, false))

  defp my_turn?(table, user_id) do
    case current_player(table, user_id) do
      nil -> false
      player -> player.seat_number == table.turn_seat and table.valid_actions.actions != []
    end
  end

  defp seconds_left(%{action_deadline: nil}, _now), do: 0

  defp seconds_left(table, now) do
    max(DateTime.diff(table.action_deadline, now, :second), 0)
  end

  defp turn_player_name(table) do
    case Enum.find(table.players, &(&1.seat_number == table.turn_seat)) do
      nil -> "Waiting"
      player -> player.username
    end
  end

  defp seat_class(seat, table) do
    [
      "seat",
      seat.hero? && "hero",
      is_nil(seat.player) && "vacant",
      table.turn_seat == seat.seat_number && "acting",
      seat.player && seat.player.folded && "folded",
      seat.player && seat.player.all_in && "all-in",
      seat.player && not seat.player.connected && "away"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp seat_state(%{folded: true}), do: "Folded"
  defp seat_state(%{all_in: true}), do: "All-in"
  defp seat_state(%{connected: false}), do: "Away"
  defp seat_state(%{in_hand: false}), do: "Sitting out"
  defp seat_state(_player), do: nil

  defp stage_label(:waiting), do: "Waiting"
  defp stage_label(:complete), do: "Hand over"
  defp stage_label(stage), do: stage |> to_string() |> String.capitalize()

  defp format_chips(amount, %{room: %{big_blind: bb}}, true)
       when is_integer(amount) and is_integer(bb) and bb > 0 do
    "#{Float.round(amount / bb * 1.0, 1)} BB"
  end

  defp format_chips(amount, _table, _bb_view), do: to_string(amount)

  defp dealer_name(table) do
    case Enum.find(table.players, &Map.get(&1, :is_dealer, false)) do
      nil -> "Table creator"
      player -> "#{player.username} (Seat #{player.seat_number})"
    end
  end

  defp can_show_cards?(nil, _table), do: false

  defp can_show_cards?(hero, table) do
    length(hero.cards) == 2 and not Map.get(hero, :revealed_cards, false) and
      (table.stage in [:complete, :showdown] or hero.folded)
  end

  defp can_pre_act?(table, user_id) do
    case current_player(table, user_id) do
      nil ->
        false

      hero ->
        table.stage in [:preflop, :flop, :turn, :river] and hero.in_hand and not hero.folded and
          not hero.all_in and not my_turn?(table, user_id)
    end
  end

  # Drives the shrinking ring around the seat that is on the clock.
  defp timer_style(table, now) do
    total = max(turn_timeout_seconds(), 1)
    remaining = seconds_left(table, now)
    fraction = remaining / total * 100

    "--timer-remaining:#{Float.round(fraction * 1.0, 1)}%"
  end

  defp turn_timeout_seconds do
    MicuPoker.Config.integer("TURN_TIMEOUT_SECONDS", 30, min: 1)
  end

  defp waiting_message(table, user_id) do
    cond do
      is_nil(current_player(table, user_id)) -> "Spectating. Take a seat from the lobby."
      table.stage == :waiting -> "Waiting for another player to sit down."
      table.stage in [:showdown, :complete] -> "Hand complete. Next hand starting shortly."
      true -> "Waiting for #{turn_player_name(table)}."
    end
  end

  defp sizing_available?(table) do
    :bet in table.valid_actions.actions or :raise in table.valid_actions.actions
  end

  defp human_error(:message_too_long), do: "message is too long"
  defp human_error(:empty_message), do: "message is empty"
  defp human_error(:rate_limited), do: "slow down"
  defp human_error(:not_your_turn), do: "it is not your turn"
  defp human_error(:not_connected), do: "you are not connected to this table"
  defp human_error(:not_seated), do: "you are not seated at this table"
  defp human_error(:invalid_action), do: "that action is not available"
  defp human_error(:bet_too_small), do: "that bet is below the minimum"
  defp human_error(:bet_too_large), do: "that bet is above your stack"
  defp human_error(:raise_too_small), do: "that raise is below the minimum"
  defp human_error(:raise_too_large), do: "that raise is above your stack"
  defp human_error(:table_unavailable), do: "the table is restarting, try again"
  defp human_error(:hand_in_progress), do: "wait for the hand to finish"
  defp human_error(:stack_not_empty), do: "you still have chips to play"
  defp human_error(:not_dealer), do: "only the table dealer/host can do that"
  defp human_error(:invalid_amount), do: "enter a valid fictional chip amount"

  defp human_error(:invalid_table_settings),
    do: "check blinds, buy-in and currency (big blind must be >= 2x small blind and <= buy-in)"

  defp human_error(:cannot_kick_self), do: "use Leave to vacate your own seat"
  defp human_error(:cannot_show_cards), do: "cards can only be shown after folding or at hand end"
  defp human_error(:invalid_reaction), do: "unknown table reaction"
  defp human_error(:room_full), do: "table has no open seats left"
  defp human_error(:seat_taken), do: "that seat is already occupied"
  defp human_error(:invalid_seat), do: "choose a valid seat number"
  defp human_error(:time_bank_already_used), do: "time bank already used in this hand"
  defp human_error(:invalid_ante), do: "ante must be between 0 and the small blind"
  defp human_error(:invalid_blind_timer), do: "blind timer must be between 0 and 60 minutes"
  defp human_error(reason), do: to_string(reason)

  defp clamp_bet_amount(amount, table, room) do
    min_amount =
      table.valid_actions[:min_raise_to] || table.valid_actions[:min_bet] || room.big_blind

    max_amount = table.valid_actions[:max_total_bet] || min_amount

    amount
    |> parse_amount(min_amount)
    |> min(max_amount)
    |> max(min_amount)
  end

  defp parse_amount(amount, _default) when is_integer(amount), do: amount

  defp parse_amount(amount, default) do
    case Integer.parse(to_string(amount)) do
      {value, ""} -> value
      _ -> default
    end
  end
end
