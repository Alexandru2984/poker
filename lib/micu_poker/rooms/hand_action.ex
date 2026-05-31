defmodule MicuPoker.Rooms.HandAction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hand_actions" do
    field :action, :string
    field :amount, :integer, default: 0
    field :street, :string
    field :created_at, :utc_datetime

    belongs_to :hand, MicuPoker.Rooms.Hand
    belongs_to :user, MicuPoker.Accounts.User
  end

  def changeset(action, attrs) do
    action
    |> cast(attrs, [:hand_id, :user_id, :action, :amount, :street, :created_at])
    |> validate_required([:action, :street, :created_at])
    |> validate_length(:action, max: 24)
    |> validate_number(:amount, greater_than_or_equal_to: 0)
  end
end
