defmodule MicuPoker.Repo.Migrations.CreateMicupokerTables do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :username, :string, null: false
      add :email, :string
      add :password_hash, :string
      add :virtual_chips, :integer, null: false, default: 1000

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:username])
    create unique_index(:users, [:email], where: "email IS NOT NULL")

    create table(:rooms) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :max_players, :integer, null: false
      add :small_blind, :integer, null: false
      add :big_blind, :integer, null: false
      add :starting_chips, :integer, null: false
      add :status, :string, null: false, default: "waiting"
      add :password_hash, :string
      add :spectator_enabled, :boolean, null: false, default: true
      add :created_by, references(:users, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:rooms, [:slug])
    create index(:rooms, [:status])

    create table(:room_players) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :seat_number, :integer, null: false
      add :stack, :integer, null: false
      add :status, :string, null: false, default: "seated"
      add :joined_at, :utc_datetime, null: false
      add :left_at, :utc_datetime
    end

    create unique_index(:room_players, [:room_id, :user_id], where: "left_at IS NULL")
    create unique_index(:room_players, [:room_id, :seat_number], where: "left_at IS NULL")

    create table(:hands) do
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :hand_number, :integer, null: false
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      add :board_cards_sanitized, :map, null: false, default: %{}
      add :winner_summary, :map, null: false, default: %{}
      add :pot_total, :integer, null: false, default: 0
    end

    create index(:hands, [:room_id, :hand_number])

    create table(:hand_actions) do
      add :hand_id, references(:hands, on_delete: :nilify_all)
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :amount, :integer, null: false, default: 0
      add :street, :string, null: false
      add :created_at, :utc_datetime, null: false
    end

    create index(:hand_actions, [:hand_id])

    create table(:chip_ledger) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :room_id, references(:rooms, on_delete: :delete_all), null: false
      add :hand_id, references(:hands, on_delete: :nilify_all)
      add :delta, :integer, null: false
      add :reason, :string, null: false
      add :created_at, :utc_datetime, null: false
    end

    create index(:chip_ledger, [:user_id])
    create index(:chip_ledger, [:room_id])
  end
end
