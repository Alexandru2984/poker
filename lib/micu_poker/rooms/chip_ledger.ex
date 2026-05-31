defmodule MicuPoker.Rooms.ChipLedger do
  use Ecto.Schema
  import Ecto.Changeset

  schema "chip_ledger" do
    field :delta, :integer
    field :reason, :string
    field :created_at, :utc_datetime

    belongs_to :user, MicuPoker.Accounts.User
    belongs_to :room, MicuPoker.Rooms.Room
    belongs_to :hand, MicuPoker.Rooms.Hand
  end

  def changeset(ledger, attrs) do
    ledger
    |> cast(attrs, [:user_id, :room_id, :hand_id, :delta, :reason, :created_at])
    |> validate_required([:user_id, :room_id, :delta, :reason, :created_at])
    |> validate_length(:reason, max: 80)
  end
end
