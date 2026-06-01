defmodule MicuPoker.RoomsTest do
  use MicuPoker.DataCase

  import Ecto.Query

  alias MicuPoker.Accounts
  alias MicuPoker.Repo
  alias MicuPoker.Rooms
  alias MicuPoker.Rooms.{Room, RoomPlayer}

  test "room creation validation rejects bad blinds" do
    {:ok, user} = Accounts.create_guest_user()

    assert {:error, changeset} =
             Rooms.create_room(
               %{
                 "name" => "Bad Room",
                 "max_players" => "6",
                 "small_blind" => "10",
                 "big_blind" => "10",
                 "starting_chips" => "1000"
               },
               user.id
             )

    assert "must be at least twice the small blind" in errors_on(changeset).big_blind
  end

  test "room creation rejects blinds larger than starting stack" do
    {:ok, user} = Accounts.create_guest_user()

    assert {:error, changeset} =
             Rooms.create_room(
               %{
                 "name" => "Broken Stack Room",
                 "max_players" => "6",
                 "small_blind" => "50",
                 "big_blind" => "100",
                 "starting_chips" => "99"
               },
               user.id
             )

    assert "must be less than or equal to starting chips" in errors_on(changeset).big_blind
  end

  test "room creation accepts strict valid values" do
    {:ok, user} = Accounts.create_guest_user()

    assert {:ok, room} =
             Rooms.create_room(
               %{
                 "name" => "Good Room",
                 "max_players" => "6",
                 "small_blind" => "5",
                 "big_blind" => "10",
                 "starting_chips" => "1000"
               },
               user.id
             )

    assert room.name == "Good Room"
    assert room.spectator_enabled
  end

  test "room creation uses configured defaults when values are omitted" do
    {:ok, user} = Accounts.create_guest_user()

    with_env(
      %{
        "DEFAULT_STARTING_CHIPS" => "1500",
        "DEFAULT_SMALL_BLIND" => "15",
        "DEFAULT_BIG_BLIND" => "30",
        "MAX_PLAYERS_PER_ROOM" => "8"
      },
      fn ->
        assert {:ok, room} =
                 Rooms.create_room(
                   %{
                     "name" => "Default Room"
                   },
                   user.id
                 )

        assert room.max_players == 6
        assert room.starting_chips == 1500
        assert room.small_blind == 15
        assert room.big_blind == 30
      end
    )
  end

  test "list rooms excludes complete rooms from lobby results" do
    {:ok, user} = Accounts.create_guest_user()
    {:ok, waiting_room} = create_room(user, "Visible Room")
    {:ok, complete_room} = create_room(user, "Complete Room")

    Rooms.update_status(complete_room.id, "complete")

    room_ids = Rooms.list_rooms() |> Enum.map(& &1.id)
    assert waiting_room.id in room_ids
    refute complete_room.id in room_ids
  end

  test "room creation enforces max active room capacity" do
    {:ok, user} = Accounts.create_guest_user()

    with_env("MAX_ROOMS", "1", fn ->
      assert {:ok, _room} = create_room(user, "Capacity One")

      assert {:error, changeset} =
               create_room(user, "Capacity Two")

      assert "maximum active rooms reached" in errors_on(changeset).base
    end)
  end

  test "complete rooms do not count against max active room capacity" do
    {:ok, user} = Accounts.create_guest_user()

    with_env("MAX_ROOMS", "1", fn ->
      {:ok, room} = create_room(user, "Finished Capacity")
      Rooms.update_status(room.id, "complete")

      assert {:ok, _room} = create_room(user, "Replacement Capacity")
    end)
  end

  test "room password input is ignored until protected rooms are implemented" do
    {:ok, user} = Accounts.create_guest_user()

    assert {:ok, room} =
             Rooms.create_room(
               %{
                 "name" => "No False Password",
                 "max_players" => "6",
                 "small_blind" => "5",
                 "big_blind" => "10",
                 "starting_chips" => "1000",
                 "password" => "not-stored"
               },
               user.id
             )

    assert room.password_hash == nil
  end

  test "expire stale rooms completes rooms and releases seats" do
    {:ok, user} = Accounts.create_guest_user()
    {:ok, room} = create_room(user, "Stale Room")
    {:ok, _player} = Rooms.seat_user(room, user.id)

    old = DateTime.add(DateTime.utc_now(:second), -2, :hour)

    Repo.update_all(from(r in Room, where: r.id == ^room.id),
      set: [status: "active", updated_at: old]
    )

    assert {:ok, %{rooms: 1, room_players: 1}} =
             Rooms.expire_stale_rooms(DateTime.add(DateTime.utc_now(:second), -1, :hour))

    assert Rooms.get_room!(room.id).status == "complete"

    assert [%{left_at: left_at, status: "left"}] =
             Repo.all(from(rp in RoomPlayer, where: rp.room_id == ^room.id))

    assert left_at
  end

  test "expire stale rooms leaves recent rooms alone" do
    {:ok, user} = Accounts.create_guest_user()
    {:ok, room} = create_room(user, "Fresh Room")
    {:ok, _player} = Rooms.seat_user(room, user.id)

    assert {:ok, %{rooms: 0, room_players: 0}} =
             Rooms.expire_stale_rooms(DateTime.add(DateTime.utc_now(:second), -1, :hour))

    assert Repo.one(from(rp in RoomPlayer, where: rp.room_id == ^room.id and is_nil(rp.left_at)))
  end

  test "janitor deletes only unused old guest users" do
    old = DateTime.add(DateTime.utc_now(:second), -2, :hour)
    cutoff = DateTime.add(DateTime.utc_now(:second), -1, :hour)

    {:ok, unused_guest} = Accounts.create_guest_user()
    {:ok, used_guest} = Accounts.create_guest_user()
    {:ok, room} = create_room(used_guest, "Used Guest Room")
    {:ok, _player} = Rooms.seat_user(room, used_guest.id)

    Repo.update_all(
      from(u in Accounts.User, where: u.id in ^[unused_guest.id, used_guest.id]),
      set: [inserted_at: old, updated_at: old]
    )

    assert {:ok, 1} = Accounts.delete_unused_guest_users(cutoff)
    refute Accounts.get_user(unused_guest.id)
    assert Accounts.get_user(used_guest.id)
  end

  defp create_room(user, name) do
    Rooms.create_room(
      %{
        "name" => name,
        "max_players" => "6",
        "small_blind" => "5",
        "big_blind" => "10",
        "starting_chips" => "1000"
      },
      user.id
    )
  end

  defp with_env(key, value, fun) do
    with_env(%{key => value}, fun)
  end

  defp with_env(values, fun) when is_map(values) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
