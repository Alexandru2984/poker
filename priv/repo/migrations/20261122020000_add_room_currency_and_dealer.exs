defmodule MicuPoker.Repo.Migrations.AddRoomCurrencyAndDealer do
  use Ecto.Migration

  def up do
    alter table(:rooms) do
      add :currency, :string, null: false, default: "CHIPS"
      add :dealer_user_id, references(:users, on_delete: :nilify_all)
    end

    execute("UPDATE rooms SET dealer_user_id = created_by WHERE dealer_user_id IS NULL")

    create index(:rooms, [:dealer_user_id])
  end

  def down do
    drop index(:rooms, [:dealer_user_id])

    alter table(:rooms) do
      remove :dealer_user_id
      remove :currency
    end
  end
end
