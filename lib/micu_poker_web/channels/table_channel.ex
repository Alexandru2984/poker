defmodule MicuPokerWeb.TableChannel do
  use Phoenix.Channel

  alias MicuPoker.RateLimiter
  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}

  @join_limit 30
  @join_window_ms 60_000

  @impl true
  def join("table:" <> room_id, _payload, socket) do
    with :ok <- allow_join(socket.assigns.user_id),
         {:ok, room} <- Rooms.fetch_room(room_id),
         :ok <- authorize_room(room, socket.assigns.user_id),
         {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
      join_table(room.id, socket)
    else
      {:error, :rate_limited} -> {:error, %{reason: "rate_limited"}}
      {:error, :locked} -> {:error, %{reason: "room_locked"}}
      _error -> {:error, %{reason: "room_not_found"}}
    end
  end

  defp allow_join(user_id) do
    case RateLimiter.hit({:channel_join, user_id}, @join_limit, @join_window_ms) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  # The socket has no access to the session, so it cannot see the unlock grant a
  # browser holds. Require the player to already own a seat instead, which they
  # can only have obtained by entering the password over HTTP.
  defp authorize_room(room, user_id) do
    cond do
      not Rooms.protected?(room) -> :ok
      room.created_by == user_id -> :ok
      Rooms.seated?(room.id, user_id) -> :ok
      true -> {:error, :locked}
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
    case current_state(socket) do
      nil -> {:reply, {:error, %{reason: "table_unavailable"}}, socket}
      state -> {:reply, {:ok, state}, socket}
    end
  end

  def handle_in("action", %{"action" => action} = payload, socket) do
    amount = Map.get(payload, "amount", 0)
    reply = TableServer.act(socket.assigns.room_id, socket.assigns.user_id, action, amount)
    {:reply, normalize_reply(reply), socket}
  end

  def handle_in("action", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("seat", %{"command" => command}, socket)
      when command in ~w(sit_out sit_in rebuy show_cards) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.user_id

    reply =
      case command do
        "sit_out" -> TableServer.sit_out(room_id, user_id)
        "sit_in" -> TableServer.sit_in(room_id, user_id)
        "rebuy" -> TableServer.rebuy(room_id, user_id)
        "show_cards" -> TableServer.show_cards(room_id, user_id)
      end

    case reply do
      {:ok, state} -> {:reply, {:ok, state}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("seat", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("react", %{"code" => code}, socket) do
    case TableServer.react(socket.assigns.room_id, socket.assigns.user_id, code) do
      {:ok, state} -> {:reply, {:ok, state}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("react", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("dealer", %{"command" => command} = payload, socket)
      when command in ~w(grant_chips set_stack reset_stacks update_table toggle_pause transfer kick_seat add_bot remove_bots) do
    room_id = socket.assigns.room_id
    user_id = socket.assigns.user_id

    reply =
      case command do
        "grant_chips" ->
          TableServer.dealer_grant_chips(
            room_id,
            user_id,
            Map.get(payload, "seat", 0),
            Map.get(payload, "amount", 0)
          )

        "set_stack" ->
          TableServer.dealer_set_stack(
            room_id,
            user_id,
            Map.get(payload, "seat", 0),
            Map.get(payload, "stack", 0)
          )

        "reset_stacks" ->
          TableServer.dealer_reset_stacks(room_id, user_id)

        "update_table" ->
          TableServer.dealer_update_table(room_id, user_id, Map.get(payload, "settings", %{}))

        "toggle_pause" ->
          TableServer.dealer_toggle_pause(room_id, user_id)

        "transfer" ->
          TableServer.dealer_transfer(room_id, user_id, Map.get(payload, "seat", 0))

        "kick_seat" ->
          TableServer.dealer_kick_seat(room_id, user_id, Map.get(payload, "seat", 0))

        "add_bot" ->
          TableServer.dealer_add_bot(room_id, user_id, Map.get(payload, "profile", "balanced"))

        "remove_bots" ->
          TableServer.dealer_remove_bots(room_id, user_id)
      end

    case reply do
      {:ok, state} -> {:reply, {:ok, state}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("dealer", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("chat", %{"message" => message}, socket) do
    reply = TableServer.chat(socket.assigns.room_id, socket.assigns.user_id, message)
    {:reply, normalize_reply(reply), socket}
  end

  def handle_in("chat", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl true
  def handle_info({:table_state, _state}, socket) do
    # The broadcast is only a signal; each client pulls its own personalised
    # view so nobody receives another player's hole cards.
    case current_state(socket) do
      nil -> {:noreply, socket}
      state -> {:noreply, push(socket, "state", state)}
    end
  end

  defp current_state(socket) do
    TableServer.state(socket.assigns.room_id, socket.assigns.user_id)
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
