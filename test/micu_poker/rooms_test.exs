defmodule MicuPoker.RoomsTest do
  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPoker.Rooms

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
end
