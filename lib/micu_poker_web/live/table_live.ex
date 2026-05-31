defmodule MicuPokerWeb.TableLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.Rooms

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    room = Rooms.get_room!(id)
    {:ok, _pid} = TableSupervisor.ensure_table(room.id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(MicuPoker.PubSub, "table:#{room.id}")
      Process.send_after(self(), :tick, 1_000)
    end

    TableServer.join(room.id, socket.assigns.current_user.id)
    table = TableServer.state(room.id, socket.assigns.current_user.id)

    {:ok,
     socket
     |> assign(:page_title, room.name)
     |> assign(:room, room)
     |> assign(:room_id, room.id)
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
    TableServer.chat(socket.assigns.room_id, socket.assigns.current_user.id, message)
    {:noreply, assign(socket, :chat_message, "")}
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
    if socket.assigns[:room_id] && socket.assigns[:current_user] do
      TableServer.disconnect(socket.assigns.room_id, socket.assigns.current_user.id)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp action?(table, action), do: action in table.valid_actions.actions

  defp current_player(table, user_id), do: Enum.find(table.players, &(&1.user_id == user_id))

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
end
