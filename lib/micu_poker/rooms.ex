defmodule MicuPoker.Rooms do
  @moduledoc """
  Persistent room metadata and compact hand history.
  """

  import Ecto.Query
  alias Ecto.Changeset
  alias Ecto.Multi
  alias MicuPoker.Repo
  alias MicuPoker.Rooms.{ChipLedger, Hand, HandAction, Room, RoomPlayer}

  def list_rooms do
    Room
    |> where([r], r.status != "complete")
    |> order_by([r], desc: r.updated_at)
    |> Repo.all()
    |> Enum.map(&with_player_count/1)
  end

  def get_room!(id), do: Room |> Repo.get!(id) |> with_player_count()

  def get_room(id) do
    case Repo.get(Room, id) do
      nil -> nil
      room -> with_player_count(room)
    end
  end

  def create_room(attrs, user_id) do
    attrs =
      normalize_room_attrs(attrs, user_id)

    changeset = Room.changeset(%Room{}, attrs)

    cond do
      changeset.valid? and room_capacity_reached?() ->
        {:error, Changeset.add_error(changeset, :base, "maximum active rooms reached")}

      true ->
        Repo.insert(changeset)
    end
  end

  def update_status(room_id, status) when status in ["waiting", "active", "complete"] do
    from(r in Room, where: r.id == ^room_id)
    |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])
  end

  def list_players(room_id) do
    RoomPlayer
    |> where([rp], rp.room_id == ^room_id and is_nil(rp.left_at))
    |> preload(:user)
    |> order_by([rp], asc: rp.seat_number)
    |> Repo.all()
  end

  def seat_user(%Room{} = room, user_id) do
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      existing =
        RoomPlayer
        |> where([rp], rp.room_id == ^room.id and rp.user_id == ^user_id and is_nil(rp.left_at))
        |> Repo.one()

      if existing do
        Repo.preload(existing, :user)
      else
        occupied =
          RoomPlayer
          |> where([rp], rp.room_id == ^room.id and is_nil(rp.left_at))
          |> select([rp], rp.seat_number)
          |> Repo.all()

        if length(occupied) >= room.max_players do
          Repo.rollback(:room_full)
        end

        seat = Enum.find(1..room.max_players, &(&1 not in occupied))

        %RoomPlayer{}
        |> RoomPlayer.changeset(%{
          room_id: room.id,
          user_id: user_id,
          seat_number: seat,
          stack: room.starting_chips,
          status: "seated",
          joined_at: now
        })
        |> Repo.insert!()
        |> Repo.preload(:user)
      end
    end)
  end

  def leave_room(room_id, user_id) do
    now = DateTime.utc_now(:second)

    from(rp in RoomPlayer,
      where: rp.room_id == ^room_id and rp.user_id == ^user_id and is_nil(rp.left_at)
    )
    |> Repo.update_all(set: [status: "left", left_at: now])
  end

  def expire_stale_rooms(cutoff \\ stale_room_cutoff()) do
    now = DateTime.utc_now(:second)

    stale_room_ids =
      Room
      |> where([r], r.status in ["active", "waiting"] and r.updated_at < ^cutoff)
      |> select([r], r.id)
      |> Repo.all()

    Multi.new()
    |> Multi.update_all(
      :room_players,
      from(rp in RoomPlayer,
        where: rp.room_id in ^stale_room_ids and is_nil(rp.left_at)
      ),
      set: [status: "left", left_at: now]
    )
    |> Multi.update_all(
      :rooms,
      from(r in Room, where: r.id in ^stale_room_ids),
      set: [status: "complete", updated_at: now]
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{room_players: {player_count, _}, rooms: {room_count, _}}} ->
        {:ok, %{rooms: room_count, room_players: player_count}}

      {:error, step, reason, changes} ->
        {:error, %{step: step, reason: reason, changes: changes}}
    end
  end

  def create_hand(room_id, hand_number) do
    %Hand{}
    |> Hand.changeset(%{
      room_id: room_id,
      hand_number: hand_number,
      started_at: DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  def finish_hand(%Hand{} = hand, attrs) do
    hand
    |> Hand.changeset(Map.put(attrs, :ended_at, DateTime.utc_now(:second)))
    |> Repo.update()
  end

  def persist_hand_result(%Hand{} = hand, attrs, players, ledger_entries) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> Multi.update(:hand, Hand.changeset(hand, Map.put(attrs, :ended_at, now)))
    |> then(fn multi ->
      Enum.reduce(players, multi, fn player, acc ->
        Multi.update_all(
          acc,
          {:stack, player.user_id},
          from(rp in RoomPlayer,
            where:
              rp.room_id == ^hand.room_id and rp.user_id == ^player.user_id and is_nil(rp.left_at)
          ),
          set: [stack: player.stack]
        )
      end)
    end)
    |> then(fn multi ->
      ledger_entries
      |> Enum.reject(&(&1.delta == 0))
      |> Enum.with_index()
      |> Enum.reduce(multi, fn {entry, index}, acc ->
        changeset =
          %ChipLedger{}
          |> ChipLedger.changeset(
            entry
            |> Map.put(:hand_id, hand.id)
            |> Map.put(:room_id, hand.room_id)
            |> Map.put(:created_at, now)
          )

        Multi.insert(acc, {:ledger, index}, changeset)
      end)
    end)
    |> Repo.transaction()
  end

  def record_action(hand_id, user_id, action, amount, street) do
    %HandAction{}
    |> HandAction.changeset(%{
      hand_id: hand_id,
      user_id: user_id,
      action: to_string(action),
      amount: amount || 0,
      street: to_string(street),
      created_at: DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  def record_ledger(entries) when is_list(entries) do
    now = DateTime.utc_now(:second)

    Multi.new()
    |> then(fn multi ->
      Enum.with_index(entries)
      |> Enum.reduce(multi, fn {entry, index}, acc ->
        changeset =
          %ChipLedger{}
          |> ChipLedger.changeset(Map.put(entry, :created_at, now))

        Multi.insert(acc, {:ledger, index}, changeset)
      end)
    end)
    |> Repo.transaction()
  end

  def stats do
    %{
      rooms: Repo.aggregate(Room, :count),
      active_rooms: Repo.aggregate(from(r in Room, where: r.status == "active"), :count),
      users: Repo.aggregate(MicuPoker.Accounts.User, :count),
      completed_hands: Repo.aggregate(from(h in Hand, where: not is_nil(h.ended_at)), :count),
      play_money_only: true
    }
  end

  def stale_room_cutoff do
    minutes = System.get_env("ROOM_IDLE_TIMEOUT_MINUTES", "240") |> String.to_integer()
    DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
  end

  def active_room_count do
    Room
    |> where([r], r.status != "complete")
    |> Repo.aggregate(:count)
  end

  def max_rooms do
    System.get_env("MAX_ROOMS", "100") |> String.to_integer()
  end

  def room_capacity_reached?, do: active_room_count() >= max_rooms()

  defp with_player_count(%Room{} = room) do
    count =
      RoomPlayer
      |> where([rp], rp.room_id == ^room.id and is_nil(rp.left_at))
      |> Repo.aggregate(:count)

    Map.put(room, :player_count, count)
  end

  defp normalize_room_attrs(attrs, user_id) do
    name = String.trim(to_string(attrs["name"] || attrs[:name] || "Table"))
    slug = unique_slug(name)

    %{
      name: name,
      slug: slug,
      max_players: int_attr(attrs, "max_players", 6),
      small_blind: int_attr(attrs, "small_blind", 5),
      big_blind: int_attr(attrs, "big_blind", 10),
      starting_chips: int_attr(attrs, "starting_chips", 1000),
      spectator_enabled: bool_attr(attrs, "spectator_enabled", true),
      password_hash: nil,
      status: "waiting",
      created_by: user_id
    }
  end

  defp unique_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")
      |> case do
        "" -> "table"
        value -> value
      end

    "#{base}-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"
  end

  defp int_attr(attrs, key, default) do
    case attrs[key] || attrs[String.to_atom(key)] do
      value when is_integer(value) -> value
      value when is_binary(value) -> String.to_integer(value)
      _ -> default
    end
  rescue
    _ -> default
  end

  defp bool_attr(attrs, key, default) do
    case attrs[key] || attrs[String.to_atom(key)] do
      value when value in [true, false] -> value
      value when value in ["true", "on", "1"] -> true
      value when value in ["false", "0"] -> false
      _ -> default
    end
  end
end
