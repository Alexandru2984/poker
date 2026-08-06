defmodule MicuPokerWeb.ApiController do
  use MicuPokerWeb, :controller

  alias MicuPoker.Rooms
  alias MicuPoker.Poker.{TableServer, TableSupervisor}

  def rooms(conn, _params) do
    json(conn, %{rooms: Enum.map(Rooms.list_rooms(), &room_json/1)})
  end

  def room(conn, %{"id" => id}) do
    with {:ok, room} <- Rooms.fetch_room(id) do
      # Read-only: never start a table process from a public endpoint.
      table =
        case TableSupervisor.lookup_table(room.id) do
          {:ok, _pid} -> public_table(room.id, current_user_id(conn))
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

  defp public_table(room_id, viewer_id) do
    case TableServer.state(room_id, viewer_id) do
      nil -> nil
      table -> redact_for_outsiders(table, viewer_id)
    end
  end

  # Table chat and the action log are for people at the table. Anyone can call
  # this endpoint without a session, so strip both unless the caller is seated.
  defp redact_for_outsiders(table, viewer_id) do
    if viewer_id && Enum.any?(table.players, &Map.get(&1, :is_me, false)) do
      table
    else
      %{table | chat: [], log: []}
    end
  end

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
