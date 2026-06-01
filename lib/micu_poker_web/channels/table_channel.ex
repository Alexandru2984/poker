defmodule MicuPokerWeb.TableChannel do
  use Phoenix.Channel

  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}

  @impl true
  def join("table:" <> room_id, _payload, socket) do
    with {:ok, room} <- Rooms.fetch_room(room_id),
         {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
      join_table(room.id, socket)
    else
      _error -> {:error, %{reason: "room_not_found"}}
    end
  end

  defp join_table(room_id, socket) do
    case TableServer.join(room_id, socket.assigns.user_id) do
      {:ok, _state} ->
        connection_ref = make_ref()
        {:ok, state} = TableServer.connect(room_id, socket.assigns.user_id, connection_ref)
        Phoenix.PubSub.subscribe(MicuPoker.PubSub, "table:#{room_id}")

        {:ok, state,
         socket |> assign(:room_id, room_id) |> assign(:connection_ref, connection_ref)}

      {:spectator, state} ->
        Phoenix.PubSub.subscribe(MicuPoker.PubSub, "table:#{room_id}")
        {:ok, state, assign(socket, :room_id, room_id)}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  @impl true
  def handle_in("state", _payload, socket) do
    {:reply, {:ok, TableServer.state(socket.assigns.room_id, socket.assigns.user_id)}, socket}
  end

  def handle_in("action", %{"action" => action} = payload, socket) do
    amount = Map.get(payload, "amount", 0)
    reply = TableServer.act(socket.assigns.room_id, socket.assigns.user_id, action, amount)
    {:reply, normalize_reply(reply), socket}
  end

  def handle_in("chat", %{"message" => message}, socket) do
    reply = TableServer.chat(socket.assigns.room_id, socket.assigns.user_id, message)
    {:reply, normalize_reply(reply), socket}
  end

  @impl true
  def handle_info({:table_state, _state}, socket) do
    push(socket, "state", TableServer.state(socket.assigns.room_id, socket.assigns.user_id))
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:room_id] && socket.assigns[:user_id] && socket.assigns[:connection_ref] do
      TableServer.disconnect(
        socket.assigns.room_id,
        socket.assigns.user_id,
        socket.assigns.connection_ref
      )
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp normalize_reply(:ok), do: {:ok, %{ok: true}}
  defp normalize_reply({:error, reason}), do: {:error, %{reason: to_string(reason)}}
end
