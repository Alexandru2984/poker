defmodule MicuPokerWeb.ApiController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}

  def rooms(conn, _params) do
    json(conn, %{rooms: Enum.map(Rooms.list_rooms(), &room_json/1)})
  end

  def room(conn, %{"id" => id}) do
    with {:ok, room} <- Rooms.fetch_room(id) do
      table =
        case TableSupervisor.lookup_table(room.id) do
          {:ok, _pid} -> TableServer.state(room.id, current_user_id(conn))
          :not_found -> nil
        end

      json(conn, %{room: room_json(room), table: table})
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "room_not_found"})
    end
  end

  def stats(conn, _params), do: json(conn, Rooms.stats())

  defp current_user_id(conn), do: conn.assigns[:current_user] && conn.assigns.current_user.id

  defp room_json(room) do
    %{
      id: room.id,
      name: room.name,
      max_players: room.max_players,
      player_count: room.player_count,
      small_blind: room.small_blind,
      big_blind: room.big_blind,
      starting_chips: room.starting_chips,
      status: room.status,
      spectator_enabled: room.spectator_enabled,
      play_money_only: true
    }
  end
end
