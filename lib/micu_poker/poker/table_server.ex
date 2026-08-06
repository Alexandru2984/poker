defmodule MicuPoker.Poker.TableServer do
  @moduledoc """
  Authoritative in-memory poker table process.
  """

  use GenServer

  alias MicuPoker.Poker.{Betting, Deck, Pot, TableState}
  alias MicuPoker.Rooms

  @timeout_tick :turn_timeout
  @call_timeout 8_000
  @idle_check_interval_ms :timer.minutes(5)

  def start_link(room_id) do
    GenServer.start_link(__MODULE__, room_id, name: via(room_id))
  end

  def via(room_id), do: {:via, Registry, {MicuPoker.TableRegistry, room_id}}

  def join(room_id, user_id), do: call(room_id, {:join, user_id})
  def connect(room_id, user_id, ref), do: call(room_id, {:connect, user_id, ref})
  def disconnect(room_id, user_id), do: call(room_id, {:disconnect, user_id})
  def disconnect(room_id, user_id, ref), do: call(room_id, {:disconnect, user_id, ref})
  def leave(room_id, user_id), do: call(room_id, {:leave, user_id})

  @doc """
  Stops dealing `user_id` in from the next hand, without giving up their seat.
  """
  def sit_out(room_id, user_id), do: call(room_id, {:sit_out, user_id})

  @doc """
  Puts `user_id` back in the game from the next hand.
  """
  def sit_in(room_id, user_id), do: call(room_id, {:sit_in, user_id})

  @doc """
  Tops a busted player back up to the table's buy-in.
  """
  def rebuy(room_id, user_id), do: call(room_id, {:rebuy, user_id})

  def act(room_id, user_id, action, amount \\ 0),
    do: call(room_id, {:act, user_id, action, amount})

  def chat(room_id, user_id, message), do: call(room_id, {:chat, user_id, message})

  def state(room_id, viewer_id \\ nil) do
    case call(room_id, {:state, viewer_id}) do
      {:error, :table_unavailable} -> nil
      state -> state
    end
  end

  # A table that is restarting, overloaded or already gone must not take the
  # caller down with it: LiveViews and channels are supervised per connection,
  # and an exit here would drop a player's whole session.
  defp call(room_id, message) do
    GenServer.call(via(room_id), message, @call_timeout)
  catch
    :exit, {reason, _details} when reason in [:noproc, :normal, :shutdown, :timeout] ->
      {:error, :table_unavailable}

    :exit, {{:shutdown, _reason}, _details} ->
      {:error, :table_unavailable}
  end

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
      dealer_seat: nil,
      small_blind_seat: nil,
      big_blind_seat: nil,
      turn_seat: nil,
      acted: MapSet.new(),
      raise_closed: MapSet.new(),
      action_deadline: nil,
      timer_ref: nil,
      next_hand_ref: nil,
      disconnect_timers: %{},
      connections: %{},
      rate_limits: %{chat: %{}, action: %{}},
      log: ["MicuPoker table opened. Play-money chips only; no real-world value."],
      chat: [],
      last_activity_at: System.monotonic_time(:millisecond),
      valid_actions_fun: &__MODULE__.valid_actions/2
    }

    schedule_idle_check()

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

  def handle_call({:sit_out, user_id}, _from, state) do
    toggle_sitting_out(state, user_id, true, "#{username(state, user_id)} is sitting out.")
  end

  def handle_call({:sit_in, user_id}, _from, state) do
    toggle_sitting_out(state, user_id, false, "#{username(state, user_id)} is back in.")
  end

  def handle_call({:rebuy, user_id}, _from, state) do
    case seated_player(state, user_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      # Checked before the hand guard: a player who still has chips is told the
      # useful thing, rather than being sent away to wait for a hand to end.
      {:ok, %{stack: stack}} when stack > 0 ->
        {:reply, {:error, :stack_not_empty}, state}

      {:ok, %{in_hand: true, folded: false}} ->
        {:reply, {:error, :hand_in_progress}, state}

      {:ok, player} ->
        amount = state.room.starting_chips
        Rooms.record_rebuy(state.room_id, user_id, amount)

        new_state =
          state
          |> update_player(user_id, &%{&1 | stack: amount, sitting_out: false})
          |> add_log("#{player.username} bought in for #{amount}.")
          |> maybe_start_hand()
          |> sync_room_status()

        broadcast(new_state)
        {:reply, {:ok, TableState.sanitize(new_state, user_id)}, new_state}
    end
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
         :ok <- validate_connected(player),
         {:ok, clean} <- clean_message(message),
         {:ok, state} <- allow_rate(state, :chat, user_id) do
      item = %{username: player.username, message: clean, at: DateTime.utc_now(:second)}
      new_state = touch(%{state | chat: [item | state.chat] |> Enum.take(40)})
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
            new_state = touch(new_state)
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
  def handle_info({@timeout_tick, token}, %{timer_ref: {_timer_ref, token}, stage: stage} = state)
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

  def handle_info({@timeout_tick, _token}, state), do: {:noreply, state}

  def handle_info({:start_next_hand, token}, %{next_hand_ref: {_timer_ref, token}} = state) do
    new_state =
      maybe_start_hand(%{
        state
        | players:
            Enum.filter(state.players, &(&1.stack > 0)) ++
              Enum.filter(state.players, &(&1.stack <= 0)),
          next_hand_ref: nil
      })
      |> sync_room_status()

    broadcast(new_state)
    {:noreply, new_state}
  end

  def handle_info({:start_next_hand, _token}, state), do: {:noreply, state}

  def handle_info({:disconnect_grace_expired, user_id, token}, state) do
    case Map.get(state.disconnect_timers, user_id) do
      {_timer_ref, ^token} ->
        state = %{state | disconnect_timers: Map.delete(state.disconnect_timers, user_id)}
        new_state = expire_disconnect_grace(state, user_id) |> sync_room_status()
        broadcast(new_state)
        {:noreply, new_state}

      _stale_or_missing ->
        {:noreply, state}
    end
  end

  # A table process is started on demand for any room and used to live forever,
  # so a burst of visited rooms leaked one GenServer each. An empty table now
  # shuts itself down; the next visitor starts a fresh one from the database.
  def handle_info(:check_idle, state) do
    schedule_idle_check()

    if idle?(state) do
      {:stop, :normal, state}
    else
      {:noreply, prune_rate_limits(state)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule_idle_check, do: Process.send_after(self(), :check_idle, @idle_check_interval_ms)

  defp idle?(state) do
    idle_for = System.monotonic_time(:millisecond) - state.last_activity_at

    Enum.empty?(state.connections) and state.stage in [:waiting, :complete, :showdown] and
      idle_for >= idle_shutdown_ms()
  end

  defp idle_shutdown_ms do
    minutes = int_env("TABLE_IDLE_SHUTDOWN_MINUTES", 20)
    minutes * 60 * 1_000
  end

  defp touch(state), do: %{state | last_activity_at: System.monotonic_time(:millisecond)}

  # Rate-limit stamps are keyed by user id and used to survive every player who
  # ever sat down. Drop entries for anyone no longer at the table.
  defp prune_rate_limits(state) do
    seated = MapSet.new(state.players, & &1.user_id)

    pruned =
      Map.new(state.rate_limits, fn {bucket, stamps} ->
        {bucket, Map.filter(stamps, fn {user_id, _at} -> MapSet.member?(seated, user_id) end)}
      end)

    %{state | rate_limits: pruned}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state)
    cancel_next_hand(state)

    Enum.each(state.disconnect_timers, fn {_user_id, timer} ->
      timer |> timer_reference() |> Process.cancel_timer()
    end)

    :ok
  end

  def valid_actions(state, player) do
    if actionable?(state, player) do
      Betting.valid_actions(state, player, state.room.big_blind)
    else
      %{actions: []}
    end
  end

  defp actionable?(state, player) do
    state.stage in [:preflop, :flop, :turn, :river] and player.in_hand and
      player.seat_number == state.turn_seat and not player.folded and not player.all_in
  end

  defp apply_action(state, user_id, action, amount, timeout? \\ false) do
    with {:ok, player} <- seated_player(state, user_id),
         :ok <- validate_connected(player, timeout?),
         :ok <- validate_turn(state, player),
         :ok <- validate_action(state, player, action, amount) do
      record_amount = action_record_amount(state, player, action, amount)

      new_state =
        state
        |> cancel_timer()
        |> commit_action(player, action, amount)
        |> record_action(player, action, record_amount, timeout?)
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
    |> Betting.bet(player.user_id, amount)
    |> add_log("#{player.username} bet #{amount}.")
  end

  defp commit_action(state, player, :raise, amount) do
    state
    |> take_chips(player.user_id, amount - player.bet)
    |> Betting.raise_to(player.user_id, amount)
    |> add_log("#{player.username} raised to #{amount}.")
  end

  defp commit_action(state, player, :all_in, _amount) do
    total = player.bet + player.stack

    state
    |> take_chips(player.user_id, player.stack)
    |> Betting.all_in(player.user_id, total)
    |> add_log("#{player.username} moved all-in for #{total}.")
    |> mark_acted(player.user_id)
  end

  defp settle_or_advance(state) do
    remaining = active_players(state)

    cond do
      # Everyone else folded; the pot is uncontested.
      length(remaining) <= 1 ->
        award_uncontested(state)

      # Somebody in this round still owes a decision.
      not betting_round_complete?(state) ->
        next_turn(state)

      # The round closed with at most one player holding chips behind, so no
      # further betting is possible. Run the board out instead of asking that
      # player to check down every remaining street on their own.
      Enum.count(remaining, &can_still_bet?/1) <= 1 ->
        state
        |> return_uncalled_bet()
        |> reveal_remaining_board()
        |> showdown()

      state.stage == :river ->
        state
        |> return_uncalled_bet()
        |> showdown()

      true ->
        advance_street(state)
    end
  end

  defp can_still_bet?(player), do: not player.all_in and player.stack > 0

  defp award_uncontested(state) do
    state = return_uncalled_bet(state)

    case active_players(state) do
      [winner] -> award_without_showdown(state, winner)
      _no_single_winner -> state
    end
  end

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
        board: state.board ++ cards
    }
    |> Betting.open_round(state.room.big_blind)
    |> reset_player_bets()
    |> add_log("#{String.upcase(to_string(stage))} dealt.")
    |> start_street_turn()
  end

  # Chips nobody matched belong to the player who put them in, whether the hand
  # ends by folds or at showdown. Returning them before settlement keeps the pot
  # honest, keeps the ledger zero-sum, and removes the possibility of a side pot
  # whose only eligible player has folded, which would strand chips.
  defp return_uncalled_bet(state) do
    contributions =
      state.players
      |> Enum.map(&{&1, contribution_of(&1)})
      |> Enum.filter(fn {_player, total} -> total > 0 end)
      |> Enum.sort_by(fn {_player, total} -> total end, :desc)

    case contributions do
      [{player, top}, {_runner_up, second} | _rest] when top > second ->
        refund(state, player, top - second)

      [{player, top}] when top > 0 ->
        refund(state, player, top)

      _nothing_to_return ->
        state
    end
  end

  defp refund(state, player, amount) when amount > 0 do
    state
    |> update_player(player.user_id, fn current ->
      %{
        current
        | stack: current.stack + amount,
          bet: max(current.bet - amount, 0),
          contribution_total: max(contribution_of(current) - amount, 0),
          all_in: false
      }
    end)
    |> Map.update!(:pot, &max(&1 - amount, 0))
    |> add_log("#{player.username} takes back #{amount} uncalled.")
  end

  defp refund(state, _player, _amount), do: state

  defp contribution_of(player), do: Map.get(player, :contribution_total, 0)

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
    playable = Enum.filter(state.players, &dealt_in?/1)

    if length(playable) >= 2 do
      start_hand(%{state | players: playable ++ Enum.reject(state.players, &dealt_in?/1)})
    else
      %{state | stage: :waiting, turn_seat: nil, action_deadline: nil}
    end
  end

  defp maybe_start_hand(state), do: state

  defp start_hand(state) do
    state = cancel_next_hand(state)

    players =
      state.players
      |> Enum.filter(&dealt_in?/1)
      |> Enum.sort_by(& &1.seat_number)

    out_players =
      state.players
      |> Enum.reject(&dealt_in?/1)
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

    # The button advances by seat, not by position in this hand's player list.
    # Indexing into a list that is re-filtered every hand made the button jump
    # backwards whenever somebody joined or busted out.
    dealer = next_seated_after(players, state.dealer_seat)
    dealer_index = Enum.find_index(players, &(&1.seat_number == dealer.seat_number))
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
          dealer_seat: dealer.seat_number,
          small_blind_seat: small.seat_number,
          big_blind_seat: big.seat_number,
          current_bet: state.room.big_blind,
          min_raise: state.room.big_blind,
          acted: MapSet.new(),
          raise_closed: MapSet.new(),
          log: Enum.take(state.log, 60)
      }
      |> take_chips(small.user_id, state.room.small_blind)
      |> take_chips(big.user_id, state.room.big_blind)
      |> add_log(
        "Hand #{state.hand_number + 1} started. Blinds #{state.room.small_blind}/#{state.room.big_blind}."
      )

    # Preflop action opens to the left of the big blind. Heads-up that wraps
    # back to the button, who is also the small blind.
    turn_index = rem(big_index + 1, length(players))

    %{state | turn_seat: Enum.at(players, turn_index).seat_number}
    |> schedule_timer()
    |> sync_room_status()
  end

  # Every street after the flop opens with the first live player to the left of
  # the button, not with whoever happened to act last on the previous street.
  defp start_street_turn(state), do: advance_turn(state, state.dealer_seat)

  defp next_turn(state), do: advance_turn(state, state.turn_seat)

  defp advance_turn(state, from_seat) do
    case Enum.find(players_after_seat(state.players, from_seat), &can_act?/1) do
      nil -> state
      next -> schedule_timer(%{state | turn_seat: next.seat_number})
    end
  end

  defp can_act?(player) do
    player.in_hand && !player.folded && !player.all_in && player.stack > 0
  end

  # Seat order starting immediately clockwise of `seat`. Comparing seat numbers
  # rather than list positions keeps the order stable when the seat itself is
  # empty, which happens whenever the button sits on a player who has left.
  defp players_after_seat(players, nil), do: Enum.sort_by(players, & &1.seat_number)

  defp players_after_seat(players, seat) do
    sorted = Enum.sort_by(players, & &1.seat_number)
    {at_or_before, after_seat} = Enum.split_with(sorted, &(&1.seat_number <= seat))

    after_seat ++ at_or_before
  end

  defp next_seated_after(players, seat) do
    case players_after_seat(players, seat) do
      [next | _rest] -> next
      [] -> hd(players)
    end
  end

  defp betting_round_complete?(state), do: Betting.round_complete?(state, state.players)

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

  defp validate_connected(player, timeout? \\ false)

  defp validate_connected(_player, true), do: :ok
  defp validate_connected(%{connected: true}, false), do: :ok
  defp validate_connected(_player, false), do: {:error, :not_connected}

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

  defp action_record_amount(state, player, :call, _amount),
    do: min(call_amount(state, player), player.stack)

  defp action_record_amount(_state, player, :all_in, _amount), do: player.bet + player.stack

  defp action_record_amount(_state, _player, action, amount) when action in [:bet, :raise],
    do: amount

  defp action_record_amount(_state, _player, _action, _amount), do: 0

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

  defp mark_acted(state, user_id), do: Betting.mark_acted(state, user_id)

  # Sitting out takes effect from the next hand: a player cannot walk away from
  # chips they have already committed to the pot.
  defp toggle_sitting_out(state, user_id, sitting_out?, message) do
    case seated_player(state, user_id) do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:ok, %{sitting_out: ^sitting_out?}} ->
        {:reply, {:ok, TableState.sanitize(state, user_id)}, state}

      {:ok, _player} ->
        new_state =
          state
          |> update_player(user_id, &%{&1 | sitting_out: sitting_out?})
          |> add_log(message)
          |> maybe_start_hand()
          |> sync_room_status()

        broadcast(new_state)
        {:reply, {:ok, TableState.sanitize(new_state, user_id)}, new_state}
    end
  end

  defp username(state, user_id) do
    case Enum.find(state.players, &(&1.user_id == user_id)) do
      nil -> "A player"
      player -> player.username
    end
  end

  # Who the next hand is dealt to. A player who is disconnected, out of chips or
  # sitting out keeps their seat but is skipped.
  defp dealt_in?(player) do
    player.connected and player.stack > 0 and not Map.get(player, :sitting_out, false)
  end

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
    state = cancel_next_hand(state)
    token = make_ref()
    timer_ref = Process.send_after(self(), {:start_next_hand, token}, next_hand_delay_ms())
    %{state | next_hand_ref: {timer_ref, token}}
  end

  defp next_hand_delay_ms, do: int_env("NEXT_HAND_DELAY_MS", 4000)

  # A malformed environment variable used to raise inside the table process and
  # take the whole hand down with it. Fall back to the default instead.
  defp int_env(name, default) do
    case Integer.parse(System.get_env(name, "")) do
      {value, ""} when value >= 0 -> value
      _invalid -> default
    end
  end

  defp schedule_timer(state) do
    seconds = int_env("TURN_TIMEOUT_SECONDS", 30)
    token = make_ref()
    timer_ref = Process.send_after(self(), {@timeout_tick, token}, seconds * 1_000)

    %{
      state
      | timer_ref: {timer_ref, token},
        action_deadline: DateTime.add(DateTime.utc_now(:second), seconds, :second)
    }
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(state) do
    state.timer_ref |> timer_reference() |> Process.cancel_timer()
    %{state | timer_ref: nil}
  end

  defp cancel_next_hand(%{next_hand_ref: nil} = state), do: state

  defp cancel_next_hand(state) do
    state.next_hand_ref |> timer_reference() |> Process.cancel_timer()
    %{state | next_hand_ref: nil}
  end

  defp timer_reference({timer_ref, _token}), do: timer_ref
  defp timer_reference(timer_ref), do: timer_ref

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
        leaving: false,
        sitting_out: false
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
    max = int_env("MAX_CHAT_MESSAGE_LENGTH", 300)
    clean = message |> to_string() |> String.trim()

    cond do
      clean == "" -> {:error, :empty_message}
      String.length(clean) > max -> {:error, :message_too_long}
      true -> {:ok, clean}
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

  defp rate_limit_interval(:chat), do: int_env("CHAT_RATE_LIMIT_MS", 1200)
  defp rate_limit_interval(:action), do: int_env("ACTION_RATE_LIMIT_MS", 400)

  defp schedule_disconnect_grace(state, user_id) do
    case Enum.find(state.players, &(&1.user_id == user_id)) do
      nil ->
        state

      _player ->
        state = cancel_disconnect_grace(state, user_id)
        seconds = int_env("DISCONNECT_GRACE_SECONDS", 60)
        token = make_ref()

        timer_ref =
          Process.send_after(self(), {:disconnect_grace_expired, user_id, token}, seconds * 1_000)

        deadline = DateTime.add(DateTime.utc_now(:second), seconds, :second)

        state
        |> Map.update!(:disconnect_timers, &Map.put(&1, user_id, {timer_ref, token}))
        |> update_player(user_id, &%{&1 | connected: false, disconnect_deadline: deadline})
    end
  end

  defp expire_disconnect_grace(state, user_id) do
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

      {timer, timers} ->
        timer |> timer_reference() |> Process.cancel_timer()

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

  # Called on every join, connect, disconnect and deal. Skip the write when the
  # status has not actually moved, so a busy table is not issuing a redundant
  # UPDATE from inside the process that also owns the hand.
  defp sync_room_status(state) do
    status = room_status(state)
    state = touch(state)

    if status == state.room.status do
      state
    else
      Rooms.update_status(state.room_id, status)
      %{state | room: %{state.room | status: status}}
    end
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

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(
      MicuPoker.PubSub,
      "table:#{state.room_id}",
      {:table_state, TableState.sanitize(state)}
    )
  end
end
