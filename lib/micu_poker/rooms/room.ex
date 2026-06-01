defmodule MicuPoker.Rooms.Room do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rooms" do
    field :name, :string
    field :slug, :string
    field :max_players, :integer, default: 6
    field :small_blind, :integer, default: 5
    field :big_blind, :integer, default: 10
    field :starting_chips, :integer, default: 1000
    field :status, :string, default: "waiting"
    field :password_hash, :string
    field :spectator_enabled, :boolean, default: true
    field :player_count, :integer, virtual: true, default: 0
    field :created_by, :id

    timestamps(type: :utc_datetime)
  end

  def changeset(room, attrs) do
    room
    |> cast(attrs, [
      :name,
      :slug,
      :max_players,
      :small_blind,
      :big_blind,
      :starting_chips,
      :status,
      :password_hash,
      :spectator_enabled,
      :created_by
    ])
    |> validate_required([
      :name,
      :slug,
      :max_players,
      :small_blind,
      :big_blind,
      :starting_chips,
      :spectator_enabled,
      :status
    ])
    |> validate_length(:name, min: 3, max: 40)
    |> validate_format(:name, ~r/^[A-Za-z0-9 _.-]+$/)
    |> validate_number(:max_players,
      greater_than_or_equal_to: 2,
      less_than_or_equal_to: max_players()
    )
    |> validate_number(:small_blind, greater_than: 0, less_than_or_equal_to: 1_000)
    |> validate_number(:big_blind, greater_than: 0, less_than_or_equal_to: 2_000)
    |> validate_number(:starting_chips,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 100_000
    )
    |> validate_blinds()
    |> validate_blinds_fit_starting_stack()
    |> unique_constraint(:slug)
  end

  def max_players do
    System.get_env("MAX_PLAYERS_PER_ROOM", "9") |> String.to_integer()
  end

  defp validate_blinds(changeset) do
    small = get_field(changeset, :small_blind)
    big = get_field(changeset, :big_blind)

    if small && big && big < small * 2 do
      add_error(changeset, :big_blind, "must be at least twice the small blind")
    else
      changeset
    end
  end

  defp validate_blinds_fit_starting_stack(changeset) do
    big = get_field(changeset, :big_blind)
    starting_chips = get_field(changeset, :starting_chips)

    if big && starting_chips && big > starting_chips do
      add_error(changeset, :big_blind, "must be less than or equal to starting chips")
    else
      changeset
    end
  end
end
