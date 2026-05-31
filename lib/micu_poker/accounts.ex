defmodule MicuPoker.Accounts do
  @moduledoc """
  Guest account helpers. v1 intentionally avoids real-money wallets.
  """

  import Ecto.Query
  alias MicuPoker.Accounts.User
  alias MicuPoker.Repo

  @default_chips 1000

  def get_user(id), do: Repo.get(User, id)

  def ensure_guest_user(nil), do: create_guest_user()

  def ensure_guest_user(id) do
    case get_user(id) do
      %User{} = user -> {:ok, user}
      nil -> create_guest_user()
    end
  end

  def create_guest_user do
    username = unique_guest_name()

    %User{}
    |> User.changeset(%{
      username: username,
      virtual_chips: default_chips(),
      password_hash: "guest"
    })
    |> Repo.insert()
  end

  def rename_user(%User{} = user, username) do
    user
    |> User.changeset(%{username: String.trim(username || "")})
    |> Repo.update()
  end

  def list_recent_users(limit \\ 20) do
    User |> order_by(desc: :inserted_at) |> limit(^limit) |> Repo.all()
  end

  def default_chips do
    System.get_env("DEFAULT_STARTING_CHIPS", "#{@default_chips}") |> String.to_integer()
  end

  defp unique_guest_name do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "Guest-#{suffix}"
  end
end
