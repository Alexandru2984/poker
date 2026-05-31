defmodule MicuPokerWeb.RoomController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}

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
    room = Rooms.get_room!(id)
    {:ok, _pid} = TableSupervisor.ensure_table(room.id)

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
    {:ok, _pid} = TableSupervisor.ensure_table(String.to_integer(id))
    TableServer.leave(String.to_integer(id), conn.assigns.current_user.id)
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
