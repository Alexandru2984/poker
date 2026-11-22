defmodule MicuPokerWeb.RoomController do
  use MicuPokerWeb, :controller

  alias MicuPoker.RateLimiter
  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}
  alias MicuPokerWeb.Plugs.RemoteIp

  @unlock_attempts_per_room 5
  @unlock_window_ms :timer.minutes(5)

  def create(conn, %{"room" => params}) do
    case Rooms.create_room(params, conn.assigns.current_user.id) do
      {:ok, room} ->
        redirect(conn, to: ~p"/rooms/#{room.id}")

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Room could not be created: #{first_error(changeset)}")
        |> redirect(to: ~p"/lobby")
    end
  end

  def join(conn, %{"id" => id}) do
    with {:ok, room} <- Rooms.fetch_room(id),
         :ok <- authorize_room(conn, room),
         {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
      join_room(conn, room)
    else
      {:error, :locked} ->
        redirect(conn, to: ~p"/rooms/#{id}/unlock")

      _error ->
        conn
        |> put_flash(:error, "Table was not found.")
        |> redirect(to: ~p"/lobby")
    end
  end

  @doc """
  Shows the password prompt for a private table.
  """
  def unlock(conn, %{"id" => id}) do
    case Rooms.fetch_room(id) do
      {:ok, room} ->
        if authorize_room(conn, room) == :ok do
          redirect(conn, to: ~p"/rooms/#{room.id}")
        else
          render(conn, :unlock, room: room, error_message: nil, page_title: room.name)
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Table was not found.")
        |> redirect(to: ~p"/lobby")
    end
  end

  def submit_unlock(conn, %{"id" => id} = params) do
    password = get_in(params, ["room", "password"]) || ""

    case Rooms.fetch_room(id) do
      {:ok, room} ->
        case check_unlock_rate(conn, room.id) do
          :ok ->
            if Rooms.password_matches?(room, password) do
              reset_unlock_rate(conn, room.id)

              conn
              |> grant_room(room.id)
              |> redirect(to: ~p"/rooms/#{room.id}")
            else
              conn
              |> put_status(:unauthorized)
              |> render(:unlock,
                room: room,
                error_message: "That table password is not correct.",
                page_title: room.name
              )
            end

          {:error, :rate_limited} ->
            conn
            |> put_status(:too_many_requests)
            |> render(:unlock,
              room: room,
              error_message: "Too many password attempts for this table. Try again later.",
              page_title: room.name
            )
        end

      {:error, :not_found} ->
        conn
        |> put_flash(:error, "Table was not found.")
        |> redirect(to: ~p"/lobby")
    end
  end

  defp check_unlock_rate(conn, room_id) do
    ip = conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)

    case RateLimiter.hit(
           {:room_unlock, ip, room_id},
           @unlock_attempts_per_room,
           @unlock_window_ms
         ) do
      {:allow, _} -> :ok
      {:deny, _} -> {:error, :rate_limited}
    end
  end

  defp reset_unlock_rate(conn, room_id) do
    ip = conn.assigns[:client_ip] || RemoteIp.format(conn.remote_ip)
    RateLimiter.reset({:room_unlock, ip, room_id})
  end

  # The creator never needs their own password.
  defp authorize_room(conn, room) do
    cond do
      not Rooms.protected?(room) -> :ok
      room.created_by == conn.assigns.current_user.id -> :ok
      room.id in unlocked_rooms(conn) -> :ok
      true -> {:error, :locked}
    end
  end

  defp grant_room(conn, room_id) do
    granted = [room_id | unlocked_rooms(conn)] |> Enum.uniq() |> Enum.take(50)

    put_session(conn, :unlocked_rooms, granted)
  end

  defp unlocked_rooms(conn) do
    case get_session(conn, :unlocked_rooms) do
      list when is_list(list) -> list
      _missing -> []
    end
  end

  defp join_room(conn, room) do
    case TableServer.join(room.id, conn.assigns.current_user.id) do
      {:ok, _state} ->
        redirect(conn, to: ~p"/rooms/#{room.id}")

      {:spectator, _state} ->
        redirect(conn, to: ~p"/rooms/#{room.id}")

      {:error, :room_full} ->
        conn
        |> put_flash(:error, "Table is full and spectators are disabled.")
        |> redirect(to: ~p"/lobby")

      {:error, reason} ->
        conn
        |> put_flash(:error, "Could not join table: #{reason}")
        |> redirect(to: ~p"/lobby")
    end
  end

  def leave(conn, %{"id" => id}) do
    with {:ok, room} <- Rooms.fetch_room(id),
         {:ok, _pid} <- TableSupervisor.ensure_table(room.id) do
      TableServer.leave(room.id, conn.assigns.current_user.id)
    end

    redirect(conn, to: ~p"/lobby")
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
end
