defmodule MicuPokerWeb.TableLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Rooms
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

    socket
    |> assign(:table, table)
    |> assign(:seats, TableLayout.seats(table, viewer_seat))
    |> assign(:bet_presets, TableLayout.bet_presets(table))
    |> assign(:bet_amount, clamp_bet_amount(socket.assigns[:bet_amount], table, table.room))
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

  def handle_event("panel", %{"panel" => panel}, socket) when panel in ~w(chat log info) do
    {:noreply, assign(socket, :panel, panel)}
  end

  def handle_event("panel", _params, socket), do: {:noreply, socket}

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

  # Drives the shrinking ring around the seat that is on the clock.
  defp timer_style(table, now) do
    total = max(turn_timeout_seconds(), 1)
    remaining = seconds_left(table, now)
    fraction = remaining / total * 100

    "--timer-remaining:#{Float.round(fraction * 1.0, 1)}%"
  end

  defp turn_timeout_seconds do
    case Integer.parse(System.get_env("TURN_TIMEOUT_SECONDS", "")) do
      {value, ""} when value > 0 -> value
      _invalid -> 30
    end
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
