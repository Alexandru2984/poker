defmodule MicuPokerWeb.LobbyLive do
  use MicuPokerWeb, :live_view

  alias MicuPoker.Accounts
  alias MicuPoker.RateLimiter
  alias MicuPoker.Rooms

  @room_create_limit 10
  @rename_limit 10
  @rate_window_ms 60_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "MicuPoker Lobby")
     |> assign(:filter, "all")
     |> assign(:room_defaults, Rooms.room_defaults())
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

  defp first_error(changeset) do
    changeset.errors
    |> Enum.map(fn
      {:base, {message, _}} -> message
      {field, {message, _}} -> "#{field} #{message}"
    end)
    |> List.first()
    |> Kernel.||("invalid values")
  end

  defp filtered_rooms(rooms, "available"),
    do: Enum.filter(rooms, &(&1.player_count < &1.max_players))

  defp filtered_rooms(rooms, "active"), do: Enum.filter(rooms, &(&1.status == "active"))
  defp filtered_rooms(rooms, "waiting"), do: Enum.filter(rooms, &(&1.status == "waiting"))
  defp filtered_rooms(rooms, _), do: rooms
end
