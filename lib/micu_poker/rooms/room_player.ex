defmodule MicuPoker.Rooms.RoomPlayer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "room_players" do
    field :seat_number, :integer
    field :stack, :integer
    field :status, :string, default: "seated"
    field :joined_at, :utc_datetime
    field :left_at, :utc_datetime

    belongs_to :room, MicuPoker.Rooms.Room
    belongs_to :user, MicuPoker.Accounts.User
  end

  def changeset(room_player, attrs) do
    room_player
    |> cast(attrs, [:room_id, :user_id, :seat_number, :stack, :status, :joined_at, :left_at])
    |> validate_required([:room_id, :user_id, :seat_number, :stack, :status, :joined_at])
    |> validate_number(:seat_number, greater_than_or_equal_to: 1, less_than_or_equal_to: 9)
    |> validate_number(:stack, greater_than_or_equal_to: 0)
    |> unique_constraint([:room_id, :user_id])
    |> unique_constraint([:room_id, :seat_number])
  end
end
