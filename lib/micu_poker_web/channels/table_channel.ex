defmodule MicuPokerWeb.TableChannel do
  use Phoenix.Channel

  alias MicuPoker.Poker.{TableServer, TableSupervisor}

  @impl true
  def join("table:" <> room_id, _payload, socket) do
    room_id = String.to_integer(room_id)
    {:ok, _pid} = TableSupervisor.ensure_table(room_id)
    Phoenix.PubSub.subscribe(MicuPoker.PubSub, "table:#{room_id}")
    TableServer.join(room_id, socket.assigns.user_id)

    {:ok, TableServer.state(room_id, socket.assigns.user_id), assign(socket, :room_id, room_id)}
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

  defp normalize_reply(:ok), do: {:ok, %{ok: true}}
  defp normalize_reply({:error, reason}), do: {:error, %{reason: to_string(reason)}}
end
