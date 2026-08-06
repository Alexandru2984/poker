defmodule MicuPoker.Accounts do
  @moduledoc """
  Player identities.

  Two kinds of identity share one table. A *guest* is created automatically on
  first visit, has no credentials, and is disposable. An *account* has a
  username and password and survives cookie loss.

  Upgrading a guest keeps the same row, so seats, hand history and chip ledger
  entries stay attached to the player instead of being orphaned.
  """

  import Ecto.Query

  alias MicuPoker.Accounts.{Password, User, UserToken}
  alias MicuPoker.Repo
  alias MicuPoker.Rooms.RoomPlayer

  @default_chips 1000

  ## Lookups

  def get_user(nil), do: nil

  def get_user(id) when is_integer(id), do: Repo.get(User, id)

  def get_user(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} when value > 0 -> Repo.get(User, value)
      _other -> nil
    end
  end

  def get_user(_id), do: nil

  def get_user_by_username(username) when is_binary(username) do
    normalized = username |> String.trim() |> String.downcase()

    Repo.one(from u in User, where: fragment("lower(?)", u.username) == ^normalized)
  end

  def get_user_by_username(_username), do: nil

  @doc """
  Returns the account matching `username` and `password`, or nil.

  Always spends the cost of one password verification, even when no such user
  exists, so response time does not disclose which usernames are registered.
  """
  def authenticate(username, password) when is_binary(username) and is_binary(password) do
    case get_user_by_username(username) do
      %User{is_guest: false, password_hash: hash} = user when is_binary(hash) ->
        if Password.verify(password, hash), do: maybe_rehash(user, password)

      %User{} ->
        # A guest account has no password; burn the time anyway.
        Password.no_user_verify()
        nil

      nil ->
        Password.no_user_verify()
        nil
    end
  end

  def authenticate(_username, _password) do
    Password.no_user_verify()
    nil
  end

  defp maybe_rehash(user, password) do
    if Password.needs_rehash?(user.password_hash) do
      {:ok, user} =
        user
        |> Ecto.Changeset.change(password_hash: Password.hash(password))
        |> Repo.update()

      user
    else
      user
    end
  end

  ## Guests

  @doc """
  Returns the stored user for `id`, creating a guest only when none exists.

  Prefer `get_user/1` on paths that cannot persist a new id back into the
  session: creating a user there produces an orphan row on every request.
  """
  def ensure_guest_user(nil), do: create_guest_user()

  def ensure_guest_user(id) do
    case get_user(id) do
      %User{} = user -> {:ok, user}
      nil -> create_guest_user()
    end
  end

  def create_guest_user do
    %User{}
    |> User.guest_changeset(%{username: unique_guest_name(), virtual_chips: default_chips()})
    |> Repo.insert()
  end

  def guest?(%User{is_guest: is_guest}), do: is_guest
  def guest?(_user), do: true

  ## Registration

  @doc """
  Registers a brand new account.
  """
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(normalize_registration(attrs))
    |> Repo.insert()
  end

  @doc """
  Turns an existing guest into a full account, keeping their id and history.
  """
  def upgrade_guest(%User{is_guest: true} = user, attrs) do
    user
    |> User.registration_changeset(normalize_registration(attrs))
    |> Repo.update()
  end

  def upgrade_guest(%User{} = user, _attrs) do
    {:error,
     user
     |> User.registration_changeset(%{})
     |> Ecto.Changeset.add_error(:username, "is already a registered account")}
  end

  def registration_changeset(user \\ %User{}, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  defp normalize_registration(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("virtual_chips", default_chips())
  end

  def rename_user(%User{} = user, username) do
    user
    |> User.changeset(%{username: String.trim(username || "")})
    |> Repo.update()
  end

  def change_password(%User{is_guest: false} = user, current_password, attrs) do
    if Password.verify(current_password || "", user.password_hash) do
      user
      |> User.registration_changeset(normalize_registration(attrs))
      |> Repo.update()
    else
      {:error,
       user
       |> User.registration_changeset(normalize_registration(attrs))
       |> Ecto.Changeset.add_error(:current_password, "is not correct")}
    end
  end

  ## Session tokens

  @doc """
  Issues a session token and returns the raw value for the cookie.
  """
  def generate_session_token(%User{} = user) do
    {token, row} = UserToken.build_session_token(user)
    Repo.insert!(row)
    token
  end

  def get_user_by_session_token(token) when is_binary(token) do
    Repo.one(UserToken.verify_session_token_query(token))
  end

  def get_user_by_session_token(_token), do: nil

  def delete_session_token(token) when is_binary(token) do
    hashed = :crypto.hash(:sha256, token)
    Repo.delete_all(UserToken.by_token_and_context_query(hashed, "session"))
    :ok
  end

  def delete_session_token(_token), do: :ok

  @doc """
  Signs the user out of every device, e.g. after a password change.
  """
  def delete_all_session_tokens(%User{} = user) do
    Repo.delete_all(UserToken.by_user_query(user))
    :ok
  end

  def delete_expired_tokens do
    {count, _} = Repo.delete_all(UserToken.expired_query())
    {:ok, count}
  end

  def touch_last_login(%User{} = user) do
    user
    |> Ecto.Changeset.change(last_login_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  ## Housekeeping

  def list_recent_users(limit \\ 20) do
    User |> order_by(desc: :inserted_at) |> limit(^limit) |> Repo.all()
  end

  @doc """
  Removes guests that never sat at a table. Registered accounts are never
  touched, however long they have been idle.
  """
  def delete_unused_guest_users(cutoff \\ unused_guest_cutoff()) do
    {count, _} =
      from(u in User,
        as: :user,
        where:
          u.is_guest == true and is_nil(u.email) and u.inserted_at < ^cutoff and
            not exists(
              from(rp in RoomPlayer,
                where: rp.user_id == parent_as(:user).id,
                select: 1
              )
            )
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  def default_chips do
    case Integer.parse(System.get_env("DEFAULT_STARTING_CHIPS", "")) do
      {value, ""} when value > 0 -> value
      _invalid -> @default_chips
    end
  end

  def unused_guest_cutoff do
    minutes =
      case Integer.parse(System.get_env("UNUSED_GUEST_RETENTION_MINUTES", "")) do
        {value, ""} when value > 0 -> value
        _invalid -> 1440
      end

    DateTime.add(DateTime.utc_now(:second), -minutes, :minute)
  end

  defp unique_guest_name do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "Guest-#{suffix}"
  end
end
