defmodule MicuPoker.Accounts.UserToken do
  @moduledoc """
  Session tokens for signed-in players.

  The cookie carries a random 32-byte token; the database stores only its
  SHA-256 digest. A leaked database dump therefore cannot be replayed as a
  login, the same reason passwords are not stored in the clear.
  """

  use Ecto.Schema

  import Ecto.Query

  alias MicuPoker.Accounts.{User, UserToken}

  @rand_size 32
  @session_validity_days 60

  @primary_key {:id, :id, autogenerate: true}
  schema "user_tokens" do
    field :token, :binary
    field :context, :string
    field :inserted_at, :utc_datetime

    belongs_to :user, User
  end

  @doc """
  Returns `{token_for_the_cookie, row_to_insert}`.
  """
  def build_session_token(user) do
    token = :crypto.strong_rand_bytes(@rand_size)

    {token,
     %UserToken{
       token: :crypto.hash(:sha256, token),
       context: "session",
       user_id: user.id,
       inserted_at: DateTime.utc_now(:second)
     }}
  end

  @doc """
  Query returning the user for a still-valid session token.
  """
  def verify_session_token_query(token) do
    hashed = :crypto.hash(:sha256, token)
    cutoff = DateTime.add(DateTime.utc_now(:second), -@session_validity_days, :day)

    from token in by_token_and_context_query(hashed, "session"),
      join: user in assoc(token, :user),
      where: token.inserted_at > ^cutoff,
      select: user
  end

  def by_token_and_context_query(hashed_token, context) do
    from UserToken, where: [token: ^hashed_token, context: ^context]
  end

  @doc """
  Query for every token belonging to `user`, used to sign out everywhere.
  """
  def by_user_query(user), do: from(t in UserToken, where: t.user_id == ^user.id)

  @doc """
  Query for tokens past their validity window, for periodic cleanup.
  """
  def expired_query(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -@session_validity_days, :day)

    from t in UserToken, where: t.inserted_at <= ^cutoff
  end

  def session_validity_days, do: @session_validity_days
end
