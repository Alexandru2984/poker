defmodule MicuPoker.Repo.Migrations.AddUserAccounts do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :is_guest, :boolean, null: false, default: true
      add :last_login_at, :utc_datetime
    end

    # v1 marked guests by storing the literal string "guest" in password_hash.
    # Replace that sentinel with a real column so a null hash unambiguously
    # means "this account cannot be logged into".
    execute(
      "UPDATE users SET is_guest = true, password_hash = NULL WHERE password_hash = 'guest'"
    )

    execute("UPDATE users SET is_guest = false WHERE password_hash IS NOT NULL")

    create index(:users, [:is_guest])

    # Usernames are compared case-insensitively so "Micu" and "micu" cannot both
    # be registered and used to impersonate one another at a table.
    create unique_index(:users, ["lower(username)"], name: :users_username_lower_index)

    create table(:user_tokens) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :token, :binary, null: false
      add :context, :string, null: false
      add :inserted_at, :utc_datetime, null: false
    end

    create index(:user_tokens, [:user_id])
    create unique_index(:user_tokens, [:context, :token])

    # Hand history is the hottest read path for the history and stats views.
    create index(:hands, [:room_id, :ended_at])
    create index(:hand_actions, [:user_id])
    create index(:chip_ledger, [:user_id, :created_at])
  end

  def down do
    drop index(:chip_ledger, [:user_id, :created_at])
    drop index(:hand_actions, [:user_id])
    drop index(:hands, [:room_id, :ended_at])

    drop table(:user_tokens)

    drop index(:users, ["lower(username)"], name: :users_username_lower_index)
    drop index(:users, [:is_guest])

    execute("UPDATE users SET password_hash = 'guest' WHERE is_guest = true")

    alter table(:users) do
      remove :last_login_at
      remove :is_guest
    end
  end
end
