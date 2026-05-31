defmodule MicuPoker.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :virtual_chips, :integer, default: 1000

    timestamps(type: :utc_datetime)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password_hash, :virtual_chips])
    |> validate_required([:username, :virtual_chips])
    |> validate_length(:username, min: 2, max: 24)
    |> validate_format(:username, ~r/^[A-Za-z0-9 _-]+$/)
    |> validate_number(:virtual_chips,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> unique_constraint(:username)
    |> unique_constraint(:email)
  end
end
