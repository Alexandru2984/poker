defmodule MicuPoker.Rooms.Hand do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hands" do
    field :hand_number, :integer
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    field :board_cards_sanitized, :map, default: %{}
    field :winner_summary, :map, default: %{}
    field :pot_total, :integer, default: 0

    belongs_to :room, MicuPoker.Rooms.Room
  end

  def changeset(hand, attrs) do
    hand
    |> cast(attrs, [
      :room_id,
      :hand_number,
      :started_at,
      :ended_at,
      :board_cards_sanitized,
      :winner_summary,
      :pot_total
    ])
    |> validate_required([:room_id, :hand_number, :started_at])
  end
end
