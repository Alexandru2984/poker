defmodule MicuPoker.Poker.TableServer do
  @moduledoc """
  Authoritative in-memory poker table process.
  """

  use GenServer

  alias MicuPoker.Poker.{Deck, Pot, TableState}
  alias MicuPoker.Rooms

  @timeout_tick :turn_timeout

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def via(room_id), do: {:via, Registry, {MicuPoker.TableRegistry, room_id}}

  def join(room_id, user_id), do: GenServer.call(via(room_id), {:join, user_id})
  def connect(room_id, user_id, ref), do: GenServer.call(via(room_id), {:connect, user_id, ref})
  def disconnect(room_id, user_id), do: GenServer.call(via(room_id), {:disconnect, user_id})

  def disconnect(room_id, user_id, ref),
    do: GenServer.call(via(room_id), {:disconnect, user_id, ref})

  def leave(room_id, user_id), do: GenServer.call(via(room_id), {:leave, user_id})
  def state(room_id, viewer_id \\ nil), do: GenServer.call(via(room_id), {:state, viewer_id})

  def act(room_id, user_id, action, amount \\ 0),
    do: GenServer.call(via(room_id), {:act, user_id, action, amount})

  def chat(room_id, user_id, message), do: GenServer.call(via(room_id), {:chat, user_id, message})

  @impl true
  def init(room_id) do
    room = Rooms.get_room!(room_id)
    players = load_players(room_id)

    state = %{
      room_id: room_id,
      room: room,
      players: players,
      deck: [],
      board: [],
      pot: 0,
      stage: :waiting,
      hand_number: 0,
      hand: nil,
      current_bet: 0,
      min_raise: room.big_blind,
      dealer_index: -1,
      dealer_seat: nil,
      small_blind_seat: nil,
      big_blind_seat: nil,
      turn_seat: nil,
      acted: MapSet.new(),
      action_deadline: nil,
      timer_ref: nil,
      disconnect_timers: %{},
      connections: %{},
      rate_limits: %{chat: %{}, action: %{}},
      log: ["MicuPoker table opened. Play-money chips only; no real-world value."],
      chat: [],
      valid_actions_fun: &__MODULE__.valid_actions/2
    }

    {:ok, maybe_start_hand(state) |> sync_room_status()}
  end

  @impl true
  def handle_call({:join, user_id}, _from, state) do
    result = Rooms.seat_user(state.room, user_id)

    case result do
      {:ok, _room_player} ->
        new_state =
          %{
            state
            | players: merge_seated_players(state.players, load_players(state.room_id)),
              room: Rooms.get_room!(state.room_id)
          }
          |> add_log("Player joined the table.")
          |> maybe_start_hand()
          |> sync_room_status()

        broadcast(new_state)
        {:reply, {:ok, TableState.sanitize(new_state, user_id)}, new_state}

      {:error, :room_full} ->
        if state.room.spectator_enabled do
          {:reply, {:spectator, TableState.sanitize(state, user_id)}, state}
        else
          {:reply, {:error, :room_full}, state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:connect, user_id, ref}, _from, state) do
    case seated_player(state, user_id) do
      {:ok, _player} ->
        new_state =
          state
          |> track_connection(user_id, ref)
          |> cancel_disconnect_grace(user_id)
          |> maybe_start_hand()
          |> sync_room_status()

        broadcast(new_state)
        {:reply, {:ok, TableState.sanitize(new_state, user_id)}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:leave, user_id}, _from, state) do
    Rooms.leave_room(state.room_id, user_id)

    new_state =
      state
      |> clear_connections(user_id)
      |> cancel_disconnect_grace(user_id)
      |> remove_or_fold_player(user_id, "A player left the table.")
      |> sync_room_status()

    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:disconnect, user_id}, _from, state) do
    new_state =
      state
      |> clear_connections(user_id)
      |> schedule_disconnect_grace(user_id)
      |> add_log("A player left the table.")
      |> sync_room_status()

    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:disconnect, user_id, ref}, _from, state) do
    state = untrack_connection(state, user_id, ref)

    new_state =
      if connected_refs?(state, user_id) do
        state
      else
        state
        |> schedule_disconnect_grace(user_id)
        |> add_log("A player left the table.")
        |> sync_room_status()
      end

    broadcast(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:state, viewer_id}, _from, state),
    do: {:reply, TableState.sanitize(state, viewer_id), state}

  def handle_call({:chat, user_id, message}, _from, state) do
    with {:ok, player} <- seated_player(state, user_id),
         {:ok, clean} <- clean_message(message),
         {:ok, state} <- allow_rate(state, :chat, user_id) do
      item = %{username: player.username, message: clean, at: DateTime.utc_now(:second)}
      new_state = %{state | chat: [item | state.chat] |> Enum.take(40)}
      broadcast(new_state)
      {:reply, :ok, new_state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:act, user_id, action, amount}, _from, state) do
    action = normalize_action(action)
    amount = normalize_amount(amount)

    case allow_rate(state, :action, user_id) do
      {:ok, limited_state} ->
        case apply_action(limited_state, user_id, action, amount) do
          {:ok, new_state} ->
            broadcast(new_state)
            {:reply, :ok, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, limited_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(@timeout_tick, %{stage: stage} = state)
      when stage in [:preflop, :flop, :turn, :river] do
    case current_player(state) do
      nil ->
        {:noreply, state}

      player ->
        action = if call_amount(state, player) == 0, do: :check, else: :fold
        {:ok, new_state} = apply_action(state, player.user_id, action, 0, true)
        broadcast(new_state)
        {:noreply, new_state}
    end
  end

  def handle_info(:start_next_hand, state) do
    new_state =
      maybe_start_hand(%{
        state
        | players:
            Enum.filter(state.players, &(&1.stack > 0)) ++
              Enum.filter(state.players, &(&1.stack <= 0))
      })
      |> sync_room_status()

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info({:disconnect_grace_expired, user_id}, state) do
    state = %{state | disconnect_timers: Map.delete(state.disconnect_timers, user_id)}

    new_state =
      case Enum.find(state.players, &(&1.user_id == user_id)) do
        nil ->
          state

        %{connected: true} ->
          state

        %{in_hand: true, folded: false} = player ->
          state
          |> cancel_timer_if_turn(player)
          |> commit_action(player, :fold, 0)
          |> record_action(player, :fold, 0, true)
          |> add_log("#{player.username} was folded after disconnect grace expired.")
          |> settle_or_advance()

        player ->
          Rooms.leave_room(state.room_id, user_id)

          state
          |> remove_player(user_id)
          |> add_log("#{player.username} was removed after disconnect grace expired.")
          |> maybe_start_hand()
      end
      |> sync_room_status()

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  def valid_actions(state, player) do
    cond do
      state.stage not in [:preflop, :flop, :turn, :river] ->
        %{actions: []}

      not player.in_hand ->
        %{actions: []}

      player.seat_number != state.turn_seat or player.folded or player.all_in ->
        %{actions: []}

      true ->
        call = call_amount(state, player)
        max_total = player.bet + player.stack

        actions =
          [:fold]
          |> maybe_add(call == 0, :check)
          |> maybe_add(call > 0 and player.stack > 0, :call)
          |> maybe_add(state.current_bet == 0 and player.stack >= state.room.big_blind, :bet)
          |> maybe_add(
            state.current_bet > 0 and max_total >= state.current_bet + state.min_raise,
            :raise
          )
          |> maybe_add(player.stack > 0, :all_in)
          |> Enum.reverse()

        %{
          actions: actions,
          call_amount: min(call, player.stack),
          min_bet: state.room.big_blind,
          min_raise_to: state.current_bet + state.min_raise,
          max_total_bet: max_total
        }
    end
  end

  defp apply_action(state, user_id, action, amount, timeout? \\ false) do
    with {:ok, player} <- seated_player(state, user_id),
         :ok <- validate_turn(state, player),
         :ok <- validate_action(state, player, action, amount) do
      new_state =
        state
        |> cancel_timer()
        |> commit_action(player, action, amount)
        |> record_action(player, action, amount, timeout?)
        |> settle_or_advance()

      {:ok, new_state}
    end
  end

  defp commit_action(state, player, :fold, _amount) do
    state
    |> update_player(player.user_id, &%{&1 | folded: true})
    |> add_log("#{player.username} folded.")
    |> mark_acted(player.user_id)
  end

  defp commit_action(state, player, :check, _amount) do
    state
    |> add_log("#{player.username} checked.")
    |> mark_acted(player.user_id)
  end

  defp commit_action(state, player, :call, _amount) do
    amount = min(call_amount(state, player), player.stack)

    state
    |> take_chips(player.user_id, amount)
    |> add_log("#{player.username} called #{amount}.")
    |> mark_acted(player.user_id)
  end

  defp commit_action(state, player, :bet, amount) do
    state
    |> take_chips(player.user_id, amount)
    |> Map.merge(%{current_bet: amount, min_raise: amount, acted: MapSet.new([player.user_id])})
    |> add_log("#{player.username} bet #{amount}.")
  end

  defp commit_action(state, player, :raise, amount) do
    raise_by = amount - state.current_bet

    state
    |> take_chips(player.user_id, amount - player.bet)
    |> Map.merge(%{
      current_bet: amount,
      min_raise: max(raise_by, state.min_raise),
      acted: MapSet.new([player.user_id])
    })
    |> add_log("#{player.username} raised to #{amount}.")
  end

  defp commit_action(state, player, :all_in, _amount) do
    total = player.bet + player.stack
    raise_by = max(total - state.current_bet, 0)

    state
    |> take_chips(player.user_id, player.stack)
    |> maybe_update_bet(total, raise_by, player.user_id)
    |> add_log("#{player.username} moved all-in for #{total}.")
    |> mark_acted(player.user_id)
  end

  defp settle_or_advance(state) do
    remaining = active_players(state)

    cond do
      length(remaining) == 1 ->
        award_without_showdown(state, hd(remaining))

      Enum.all?(remaining, & &1.all_in) ->
        state
        |> reveal_remaining_board()
        |> showdown()

      betting_round_complete?(state) ->
        advance_street(state)

      true ->
        next_turn(state)
    end
  end

  defp advance_street(%{stage: :river} = state), do: showdown(state)

  defp advance_street(state) do
    {stage, draw_count} =
      case state.stage do
        :preflop -> {:flop, 3}
        :flop -> {:turn, 1}
        :turn -> {:river, 1}
      end

    {cards, deck} = Deck.deal(state.deck, draw_count)

    %{
      state
      | stage: stage,
        deck: deck,
        board: state.board ++ cards,
        current_bet: 0,
        min_raise: state.room.big_blind,
        acted: MapSet.new()
    }
    |> reset_player_bets()
    |> add_log("#{String.upcase(to_string(stage))} dealt.")
    |> next_turn()
  end

  defp showdown(state) do
    board = state.board
    pot_total = state.pot
    original_players = state.players
    settlement = Pot.settle_showdown(state.players, board)

    summary =
      settlement.awards
      |> Enum.map(fn award ->
        "#{award.username} wins #{award.amount} with #{MicuPoker.Poker.HandSummary.human_rank(award.eval.name)}"
      end)
      |> Enum.join(", ")

    state =
      %{
        state
        | players: settlement.players,
          stage: :showdown,
          pot: 0,
          current_bet: 0,
          turn_seat: nil,
          action_deadline: nil
      }
      |> add_log("Showdown: #{summary}.")
      |> persist_finished_hand(settlement.awards, original_players, board, pot_total, "showdown")
      |> schedule_next_hand()

    state
  end

  defp award_without_showdown(state, winner) do
    original_players = state.players

    state =
      state
      |> update_player(winner.user_id, &%{&1 | stack: &1.stack + state.pot, bet: 0})
      |> reset_player_bets()
      |> reset_contributions()
      |> Map.merge(%{
        stage: :complete,
        pot: 0,
        current_bet: 0,
        turn_seat: nil,
        action_deadline: nil
      })
      |> add_log("#{winner.username} wins the pot uncontested.")
      |> persist_finished_hand(
        [
          %{
            user_id: winner.user_id,
            username: winner.username,
            amount: state.pot,
            eval: %{name: :uncontested, score: [0]}
          }
        ],
        original_players,
        state.board,
        state.pot,
        "uncontested"
      )
      |> schedule_next_hand()

    state
  end

  defp maybe_start_hand(%{stage: stage} = state) when stage in [:waiting, :complete, :showdown] do
    state = %{state | players: Enum.reject(state.players, &Map.get(&1, :leaving, false))}
    playable = Enum.filter(state.players, &(&1.connected && &1.stack > 0))

    if length(playable) >= 2 do
      start_hand(%{
        state
        | players: playable ++ Enum.reject(state.players, &(&1.connected && &1.stack > 0))
      })
    else
      %{state | stage: :waiting, turn_seat: nil, action_deadline: nil}
    end
  end

  defp maybe_start_hand(state), do: state

  defp start_hand(state) do
    players =
      state.players
      |> Enum.filter(&(&1.connected && &1.stack > 0))
      |> Enum.sort_by(& &1.seat_number)

    out_players =
      state.players
      |> Enum.reject(&(&1.connected && &1.stack > 0))
      |> Enum.sort_by(& &1.seat_number)

    deck = Deck.shuffle()
    {hole_cards, deck} = Deck.deal(deck, length(players) * 2)

    players =
      players
      |> Enum.with_index()
      |> Enum.map(fn {player, index} ->
        cards = [Enum.at(hole_cards, index * 2), Enum.at(hole_cards, index * 2 + 1)]

        %{
          player
          | cards: cards,
            folded: false,
            all_in: false,
            bet: 0,
            contribution_total: 0,
            connected: true,
            disconnect_deadline: nil,
            leaving: false,
            in_hand: true
        }
      end)

    dealer_index = rem(max(state.dealer_index, -1) + 1, length(players))
    dealer = Enum.at(players, dealer_index)
    heads_up = length(players) == 2
    small_index = if heads_up, do: dealer_index, else: rem(dealer_index + 1, length(players))
    big_index = rem(small_index + 1, length(players))
    small = Enum.at(players, small_index)
    big = Enum.at(players, big_index)
    {:ok, hand} = Rooms.create_hand(state.room_id, state.hand_number + 1)

    state =
      %{
        state
        | players:
            players ++
              Enum.map(
                out_players,
                &%{&1 | cards: [], bet: 0, contribution_total: 0, in_hand: false}
              ),
          deck: deck,
          board: [],
          pot: 0,
          stage: :preflop,
          hand_number: state.hand_number + 1,
          hand: hand,
          dealer_index: dealer_index,
          dealer_seat: dealer.seat_number,
          small_blind_seat: small.seat_number,
          big_blind_seat: big.seat_number,
          current_bet: state.room.big_blind,
          min_raise: state.room.big_blind,
          acted: MapSet.new(),
          log: Enum.take(state.log, 60)
      }
      |> take_chips(small.user_id, state.room.small_blind)
      |> take_chips(big.user_id, state.room.big_blind)
      |> add_log(
        "Hand #{state.hand_number + 1} started. Blinds #{state.room.small_blind}/#{state.room.big_blind}."
      )

    turn_index = rem(big_index + 1, length(players))

    %{state | turn_seat: Enum.at(players, turn_index).seat_number}
    |> schedule_timer()
    |> sync_room_status()
  end

  defp next_turn(state) do
    players = ordered_players_from_next_seat(state)

    next =
      Enum.find(players, fn player ->
        player.in_hand && !player.folded && !player.all_in && player.stack > 0
      end)

    if next do
      %{state | turn_seat: next.seat_number}
      |> schedule_timer()
    else
      state
    end
  end

  defp ordered_players_from_next_seat(state) do
    sorted = Enum.sort_by(state.players, & &1.seat_number)
    current_index = Enum.find_index(sorted, &(&1.seat_number == state.turn_seat)) || -1

    1..length(sorted)
    |> Enum.map(fn offset -> Enum.at(sorted, rem(current_index + offset, length(sorted))) end)
  end

  defp betting_round_complete?(state) do
    state.players
    |> Enum.filter(&(&1.in_hand && !&1.folded && !&1.all_in))
    |> Enum.all?(fn player ->
      player.bet == state.current_bet && MapSet.member?(state.acted, player.user_id)
    end)
  end

  defp reveal_remaining_board(state) do
    needed = 5 - length(state.board)
    {cards, deck} = Deck.deal(state.deck, needed)
    %{state | board: state.board ++ cards, deck: deck}
  end

  defp validate_turn(state, player) do
    if state.stage in [:preflop, :flop, :turn, :river] && state.turn_seat == player.seat_number do
      :ok
    else
      {:error, :not_your_turn}
    end
  end

  defp validate_action(state, player, action, amount) do
    valid = valid_actions(state, player)

    cond do
      action not in valid.actions -> {:error, :invalid_action}
      action == :bet and amount < valid.min_bet -> {:error, :bet_too_small}
      action == :bet and amount > valid.max_total_bet -> {:error, :bet_too_large}
      action == :raise and amount < valid.min_raise_to -> {:error, :raise_too_small}
      action == :raise and amount > valid.max_total_bet -> {:error, :raise_too_large}
      true -> :ok
    end
  end

  defp call_amount(state, player), do: max(state.current_bet - player.bet, 0)

  defp take_chips(state, user_id, amount) do
    player = Enum.find(state.players, &(&1.user_id == user_id))
    taken = min(player.stack, amount)

    update_player(state, user_id, fn player ->
      %{
        player
        | stack: player.stack - taken,
          bet: player.bet + taken,
          contribution_total: Map.get(player, :contribution_total, 0) + taken,
          all_in: player.stack - taken == 0
      }
    end)
    |> Map.update!(:pot, &(&1 + taken))
  end

  defp maybe_update_bet(state, total, raise_by, user_id) do
    if total > state.current_bet do
      %{
        state
        | current_bet: total,
          min_raise: max(raise_by, state.min_raise),
          acted: MapSet.new([user_id])
      }
    else
      state
    end
  end

  defp update_player(state, user_id, fun) do
    %{
      state
      | players:
          Enum.map(state.players, fn player ->
            if player.user_id == user_id, do: fun.(player), else: player
          end)
    }
  end

  defp reset_player_bets(state) do
    %{state | players: Enum.map(state.players, &%{&1 | bet: 0})}
  end

  defp reset_contributions(state) do
    %{state | players: Enum.map(state.players, &Map.put(&1, :contribution_total, 0))}
  end

  defp mark_acted(state, user_id), do: %{state | acted: MapSet.put(state.acted, user_id)}

  defp active_players(state), do: Enum.filter(state.players, &(&1.in_hand && !&1.folded))
  defp current_player(state), do: Enum.find(state.players, &(&1.seat_number == state.turn_seat))

  defp seated_player(state, user_id) do
    case Enum.find(state.players, &(&1.user_id == user_id)) do
      nil -> {:error, :not_seated}
      player -> {:ok, player}
    end
  end

  defp record_action(state, player, action, amount, timeout?) do
    suffix = if timeout?, do: "timeout_", else: ""

    if state.hand,
      do:
        Rooms.record_action(
          state.hand.id,
          player.user_id,
          "#{suffix}#{action}",
          amount,
          state.stage
        )

    state
  end

  defp persist_finished_hand(state, awards, original_players, board, pot_total, reason) do
    if state.hand do
      Rooms.persist_hand_result(
        state.hand,
        %{
          board_cards_sanitized: %{cards: Enum.map(board, &MicuPoker.Poker.Card.label/1)},
          winner_summary: %{
            winners:
              Enum.map(awards, fn award ->
                %{
                  user_id: award.user_id,
                  username: award.username,
                  amount: award.amount,
                  hand: MicuPoker.Poker.HandSummary.human_rank(award.eval.name)
                }
              end)
          },
          pot_total: pot_total
        },
        state.players,
        ledger_entries(state.room_id, original_players, awards, reason)
      )
    end

    state
  end

  defp ledger_entries(room_id, original_players, awards, reason) do
    contributions =
      original_players
      |> Map.new(fn player -> {player.user_id, Map.get(player, :contribution_total, 0)} end)

    award_totals =
      awards
      |> Enum.group_by(& &1.user_id)
      |> Map.new(fn {user_id, entries} -> {user_id, Enum.sum(Enum.map(entries, & &1.amount))} end)

    (Map.keys(contributions) ++ Map.keys(award_totals))
    |> Enum.uniq()
    |> Enum.map(fn user_id ->
      %{
        user_id: user_id,
        room_id: room_id,
        delta: Map.get(award_totals, user_id, 0) - Map.get(contributions, user_id, 0),
        reason: reason
      }
    end)
  end

  defp schedule_next_hand(state) do
    Process.send_after(self(), :start_next_hand, 4_000)
    state
  end

  defp schedule_timer(state) do
    seconds = System.get_env("TURN_TIMEOUT_SECONDS", "30") |> String.to_integer()
    ref = Process.send_after(self(), @timeout_tick, seconds * 1_000)

    %{
      state
      | timer_ref: ref,
        action_deadline: DateTime.add(DateTime.utc_now(:second), seconds, :second)
    }
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    Process.cancel_timer(state.timer_ref)
    %{state | timer_ref: nil}
  end

  defp cancel_timer_if_turn(state, player) do
    if state.turn_seat == player.seat_number, do: cancel_timer(state), else: state
  end

  defp load_players(room_id) do
    room_id
    |> Rooms.list_players()
    |> Enum.map(fn rp ->
      %{
        user_id: rp.user_id,
        username: rp.user.username,
        seat_number: rp.seat_number,
        stack: rp.stack,
        bet: 0,
        contribution_total: 0,
        cards: [],
        folded: false,
        all_in: false,
        in_hand: false,
        connected: false,
        disconnect_deadline: nil,
        leaving: false
      }
    end)
  end

  defp merge_seated_players(current_players, seated_players) do
    current_by_user = Map.new(current_players, &{&1.user_id, &1})

    seated_players
    |> Enum.map(fn seated ->
      case Map.fetch(current_by_user, seated.user_id) do
        {:ok, current} ->
          %{
            current
            | username: seated.username,
              seat_number: seated.seat_number
          }

        :error ->
          seated
      end
    end)
    |> Enum.sort_by(& &1.seat_number)
  end

  defp add_log(state, message) do
    timestamp = DateTime.utc_now(:second) |> Calendar.strftime("%H:%M:%S")
    %{state | log: ["#{timestamp} #{message}" | state.log] |> Enum.take(120)}
  end

  defp clean_message(message) do
    max = System.get_env("MAX_CHAT_MESSAGE_LENGTH", "300") |> String.to_integer()
    clean = message |> to_string() |> String.trim() |> String.slice(0, max)

    if clean == "" do
      {:error, :empty_message}
    else
      {:ok, clean}
    end
  end

  defp allow_rate(state, bucket, user_id) when bucket in [:chat, :action] do
    now = System.monotonic_time(:millisecond)
    interval = rate_limit_interval(bucket)
    bucket_limits = Map.get(state.rate_limits, bucket, %{})
    last = Map.get(bucket_limits, user_id, now - interval)

    if now - last >= interval do
      {:ok, put_in(state, [:rate_limits, bucket, user_id], now)}
    else
      {:error, :rate_limited}
    end
  end

  defp rate_limit_interval(:chat),
    do: System.get_env("CHAT_RATE_LIMIT_MS", "1200") |> String.to_integer()

  defp rate_limit_interval(:action),
    do: System.get_env("ACTION_RATE_LIMIT_MS", "400") |> String.to_integer()

  defp schedule_disconnect_grace(state, user_id) do
    case Enum.find(state.players, &(&1.user_id == user_id)) do
      nil ->
        state

      _player ->
        state = cancel_disconnect_grace(state, user_id)
        seconds = System.get_env("DISCONNECT_GRACE_SECONDS", "60") |> String.to_integer()
        ref = Process.send_after(self(), {:disconnect_grace_expired, user_id}, seconds * 1_000)
        deadline = DateTime.add(DateTime.utc_now(:second), seconds, :second)

        state
        |> Map.update!(:disconnect_timers, &Map.put(&1, user_id, ref))
        |> update_player(user_id, &%{&1 | connected: false, disconnect_deadline: deadline})
    end
  end

  defp track_connection(state, user_id, ref) do
    update_in(state.connections, fn connections ->
      Map.update(connections, user_id, MapSet.new([ref]), &MapSet.put(&1, ref))
    end)
  end

  defp untrack_connection(state, user_id, ref) do
    update_in(state.connections, fn connections ->
      connections
      |> Map.update(user_id, MapSet.new(), &MapSet.delete(&1, ref))
      |> Map.reject(fn {_user_id, refs} -> MapSet.size(refs) == 0 end)
    end)
  end

  defp clear_connections(state, user_id) do
    %{state | connections: Map.delete(state.connections, user_id)}
  end

  defp connected_refs?(state, user_id) do
    state.connections
    |> Map.get(user_id, MapSet.new())
    |> MapSet.size()
    |> Kernel.>(0)
  end

  defp cancel_disconnect_grace(state, user_id) do
    case Map.pop(state.disconnect_timers, user_id) do
      {nil, _timers} ->
        update_player(state, user_id, &%{&1 | connected: true, disconnect_deadline: nil})

      {ref, timers} ->
        Process.cancel_timer(ref)

        state
        |> Map.put(:disconnect_timers, timers)
        |> update_player(user_id, &%{&1 | connected: true, disconnect_deadline: nil})
    end
  end

  defp remove_or_fold_player(state, user_id, message) do
    case Enum.find(state.players, &(&1.user_id == user_id)) do
      nil ->
        state

      %{in_hand: true, folded: false} = player ->
        state
        |> cancel_timer_if_turn(player)
        |> update_player(user_id, &%{&1 | connected: false, leaving: true})
        |> commit_action(%{player | connected: false, leaving: true}, :fold, 0)
        |> record_action(player, :fold, 0, false)
        |> add_log(message)
        |> settle_or_advance()

      _player ->
        state
        |> remove_player(user_id)
        |> add_log(message)
        |> maybe_start_hand()
    end
  end

  defp sync_room_status(state) do
    status = room_status(state)
    Rooms.update_status(state.room_id, status)

    %{state | room: %{state.room | status: status}}
  end

  defp room_status(state) do
    connected_count = Enum.count(state.players, &(&1.connected && !Map.get(&1, :leaving, false)))

    cond do
      connected_count == 0 -> "complete"
      connected_count < 2 -> "waiting"
      true -> "active"
    end
  end

  defp remove_player(state, user_id) do
    %{state | players: Enum.reject(state.players, &(&1.user_id == user_id))}
  end

  defp normalize_action(action) when is_atom(action), do: action

  defp normalize_action(action) do
    action |> to_string() |> String.replace("-", "_") |> String.to_existing_atom()
  rescue
    ArgumentError -> :invalid
  end

  defp normalize_amount(amount) when is_integer(amount), do: amount

  defp normalize_amount(amount) when is_binary(amount) do
    String.to_integer(amount)
  rescue
    _ -> 0
  end

  defp normalize_amount(_), do: 0

  defp maybe_add(actions, true, action), do: [action | actions]
  defp maybe_add(actions, false, _action), do: actions

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      MicuPoker.PubSub,
      "table:#{state.room_id}",
      {:table_state, TableState.sanitize(state)}
    )
  end
end
