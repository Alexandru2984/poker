defmodule MicuPokerWeb.TableLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Rooms

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    room = Rooms.get_room!(id)
    {:ok, _pid} = TableSupervisor.ensure_table(room.id)

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
     |> assign(:table, table)
     |> assign(:now, DateTime.utc_now(:second))
     |> assign(:bet_amount, table.valid_actions[:min_bet] || room.big_blind)
     |> assign(:chat_message, "")}
  end

  @impl true
  def handle_event("act", %{"action" => action} = params, socket) do
    amount = Map.get(params, "amount", socket.assigns.bet_amount)

    case TableServer.act(socket.assigns.room_id, socket.assigns.current_user.id, action, amount) do
      :ok ->
        {:noreply,
         assign(
           socket,
           :table,
           TableServer.state(socket.assigns.room_id, socket.assigns.current_user.id)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Action rejected: #{reason}")}
    end
  end

  def handle_event("bet_amount", %{"amount" => amount}, socket) do
    {:noreply, assign(socket, :bet_amount, amount)}
  end

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
    {:noreply,
     assign(
       socket,
       :table,
       TableServer.state(socket.assigns.room_id, socket.assigns.current_user.id)
     )}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 1_000)
    {:noreply, assign(socket, :now, DateTime.utc_now(:second))}
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

  defp seat_class(player, table) do
    base = "seat seat-#{player.seat_number}"

    cond do
      table.turn_seat == player.seat_number -> base <> " acting"
      player.folded -> base <> " folded"
      true -> base
    end
  end

  defp human_error(:message_too_long), do: "message is too long"
  defp human_error(:empty_message), do: "message is empty"
  defp human_error(:rate_limited), do: "slow down"
  defp human_error(reason), do: to_string(reason)
end
