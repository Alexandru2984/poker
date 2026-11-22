defmodule MicuPokerWeb.LobbyLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPoker.RateLimiter
  alias MicuPoker.Rooms
  alias MicuPoker.Rooms.Room

  @room_create_limit 10
  @rename_limit 10
  @rate_window_ms 60_000

  @stake_presets %{
    "micro" => %{small_blind: 5, big_blind: 10, starting_chips: 1000},
    "low" => %{small_blind: 10, big_blind: 25, starting_chips: 2500},
    "mid" => %{small_blind: 25, big_blind: 50, starting_chips: 5000},
    "high" => %{small_blind: 100, big_blind: 200, starting_chips: 20000}
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MicuPoker.PubSub, "lobby:rooms")
    end

    defaults = Rooms.room_defaults()

    {:ok,
     socket
     |> assign(:page_title, "MicuPoker Lobby")
     |> assign(:filter, "all")
     |> assign(:search, "")
     |> assign(:currencies, Room.currencies())
     |> assign(:room_defaults, defaults)
     |> assign(:rooms, Rooms.list_rooms())
     |> assign(:room_form, to_form(%{}, as: :room))
     |> assign(
       :name_form,
       to_form(%{"username" => socket.assigns.current_user.username}, as: :user)
     )}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  def handle_event("search", %{"q" => query}, socket) do
    {:noreply, assign(socket, :search, String.trim(to_string(query)))}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, :rooms, Rooms.list_rooms())}
  end

  def handle_event("stake_preset", %{"preset" => preset}, socket) do
    case Map.get(@stake_presets, preset) do
      nil ->
        {:noreply, socket}

      stakes ->
        defaults = Map.merge(socket.assigns.room_defaults, stakes)
        {:noreply, assign(socket, :room_defaults, defaults)}
    end
  end

  def handle_event("rename", %{"user" => %{"username" => username}}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.hit({:rename_user, user_id}, @rename_limit, @rate_window_ms) do
      {:allow, _} ->
        case Accounts.rename_user(socket.assigns.current_user, username) do
          {:ok, user} ->
            {:noreply, socket |> assign(:current_user, user) |> put_flash(:info, "Name updated.")}

          {:error, _changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Use 2-24 letters, numbers, spaces, dashes, or underscores."
             )}
        end

      {:deny, _} ->
        {:noreply,
         put_flash(socket, :error, "You are updating your name too quickly. Wait a moment.")}
    end
  end

  def handle_event("create_room", %{"room" => params}, socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.hit({:room_create_user, user_id}, @room_create_limit, @rate_window_ms) do
      {:allow, _} ->
        case Rooms.create_room(params, user_id) do
          {:ok, room} ->
            {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.id}")}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Room validation failed: #{first_error(changeset)}")
             |> assign(:room_form, to_form(changeset, as: :room))}
        end

      {:deny, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are creating or joining tables too quickly. Wait a moment."
         )}
    end
  end

  def handle_event("quick_practice", params, socket) do
    user = socket.assigns.current_user
    bot_count = params |> Map.get("bots", "2") |> parse_bot_count()
    defaults = socket.assigns.room_defaults

    case RateLimiter.hit({:room_create_user, user.id}, @room_create_limit, @rate_window_ms) do
      {:allow, _} ->
        room_attrs = %{
          "name" => String.slice("#{user.username} Practice", 0, 38),
          "max_players" => "6",
          "starting_chips" => to_string(defaults.starting_chips),
          "small_blind" => to_string(defaults.small_blind),
          "big_blind" => to_string(defaults.big_blind),
          "currency" => defaults.currency,
          "spectator_enabled" => "true"
        }

        with {:ok, room} <- Rooms.create_room(room_attrs, user.id),
             {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
          TableServer.join(room.id, user.id)

          profiles = ~w(tag lag balanced station)

          for idx <- 1..bot_count do
            profile = Enum.at(profiles, rem(idx - 1, length(profiles)))
            TableServer.dealer_add_bot(room.id, user.id, profile)
          end

          {:noreply, push_navigate(socket, to: ~p"/rooms/#{room.id}")}
        else
          {:error, changeset} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not launch practice table: #{first_error(changeset)}"
             )}
        end

      {:deny, _} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You are creating or joining tables too quickly. Wait a moment."
         )}
    end
  end

  @impl true
  def handle_info(:rooms_updated, socket) do
    {:noreply, assign(socket, :rooms, Rooms.list_rooms())}
  end

  defp parse_bot_count(value) do
    case Integer.parse(to_string(value)) do
      {n, ""} when n in 1..5 -> n
      _ -> 2
    end
  end

  defp first_error(changeset) do
    changeset.errors
    |> Enum.map(fn
      {:base, {message, _}} -> message
      {field, {message, _}} -> "#{field} #{message}"
    end)
    |> List.first()
    |> Kernel.||("invalid values")
  end

  defp filtered_rooms(rooms, filter, search) do
    rooms
    |> filter_by_status(filter)
    |> filter_by_search(search)
  end

  defp filter_by_status(rooms, "available"),
    do: Enum.filter(rooms, &(&1.player_count < &1.max_players))

  defp filter_by_status(rooms, "active"), do: Enum.filter(rooms, &(&1.status == "active"))
  defp filter_by_status(rooms, "waiting"), do: Enum.filter(rooms, &(&1.status == "waiting"))
  defp filter_by_status(rooms, _), do: rooms

  defp filter_by_search(rooms, ""), do: rooms

  defp filter_by_search(rooms, query) when is_binary(query) do
    down = String.downcase(query)

    Enum.filter(rooms, fn room ->
      String.contains?(String.downcase(room.name), down) or
        String.contains?(String.downcase(room.currency || "chips"), down)
    end)
  end
end
