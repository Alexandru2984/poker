defmodule MicuPoker.Accounts.User do
  use Ecto.Schema

  import Ecto.Changeset

  alias MicuPoker.Accounts.Password

  @username_format ~r/^[A-Za-z0-9 _-]+$/
  @min_password_length 10
  @max_password_length 200

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :virtual_chips, :integer, default: 1000
    field :is_guest, :boolean, default: true
    field :last_login_at, :utc_datetime

    field :password, :string, virtual: true, redact: true
    field :password_confirmation, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for player-supplied profile fields. Never touches credentials.
  """
  def changeset(user, attrs), do: profile_changeset(user, attrs, reserved_names: true)

  @doc """
  Changeset for creating a fresh guest identity.

  Skips the reserved-name rule, since "Guest-…" is exactly the shape this
  generates; the rule exists to stop players from claiming that shape.
  """
  def guest_changeset(user, attrs) do
    user
    |> profile_changeset(attrs, reserved_names: false)
    |> put_change(:is_guest, true)
    |> put_change(:password_hash, nil)
  end

  defp profile_changeset(user, attrs, opts) do
    user
    |> cast(attrs, [:username, :email, :virtual_chips])
    |> validate_required([:username, :virtual_chips])
    |> validate_username(Keyword.fetch!(opts, :reserved_names))
    |> validate_email()
    |> validate_number(:virtual_chips,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 1_000_000
    )
    |> unique_constraint(:username)
    |> unique_constraint(:username, name: :users_username_lower_index)
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for registering an account, or for turning a guest into one.

  Keeping the same row on upgrade means the player's seats, hand history and
  chip ledger entries stay attached to them.
  """
  def registration_changeset(user, attrs) do
    user
    |> changeset(attrs)
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password])
    |> validate_length(:password,
      min: @min_password_length,
      max: @max_password_length,
      count: :bytes
    )
    |> validate_password_strength()
    |> validate_confirmation(:password, message: "does not match")
    |> put_password_hash()
    |> put_change(:is_guest, false)
  end

  defp validate_username(changeset, reserved_names?) do
    changeset =
      changeset
      |> update_change(:username, &String.trim/1)
      |> validate_required([:username])
      |> validate_length(:username, min: 2, max: 24)
      |> validate_format(:username, @username_format,
        message: "may only contain letters, numbers, spaces, dashes and underscores"
      )

    if reserved_names?, do: validate_not_reserved(changeset), else: changeset
  end

  # "Guest-…" is how automatically created identities are named. Letting someone
  # register that shape would let them pass themselves off as another player.
  defp validate_not_reserved(changeset) do
    validate_change(changeset, :username, fn :username, username ->
      if String.match?(username, ~r/^guest[-_ ]/i) do
        [username: "cannot start with \"Guest-\""]
      else
        []
      end
    end)
  end

  defp validate_email(changeset) do
    case get_change(changeset, :email) do
      nil ->
        changeset

      "" ->
        put_change(changeset, :email, nil)

      _email ->
        changeset
        |> update_change(:email, &(&1 |> String.trim() |> String.downcase()))
        |> validate_format(:email, ~r/^[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+$/,
          message: "must be a valid email address"
        )
        |> validate_length(:email, max: 160)
    end
  end

  # Length alone lets through "aaaaaaaaaaaa". Require some variety without
  # imposing the character-class rules that push people towards "Password1!".
  defp validate_password_strength(changeset) do
    validate_change(changeset, :password, fn :password, password ->
      distinct = password |> String.graphemes() |> Enum.uniq() |> length()

      if distinct < 5 do
        [password: "is too repetitive, use a longer or more varied passphrase"]
      else
        []
      end
    end)
  end

  defp put_password_hash(changeset) do
    case changeset do
      %Ecto.Changeset{valid?: true, changes: %{password: password}} ->
        changeset
        |> put_change(:password_hash, Password.hash(password))
        |> delete_change(:password)
        |> delete_change(:password_confirmation)

      _invalid ->
        changeset
    end
  end

  def min_password_length, do: @min_password_length
end
