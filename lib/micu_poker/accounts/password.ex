defmodule MicuPoker.Accounts.Password do
  @moduledoc """
  Password hashing with PBKDF2-HMAC-SHA512.

  Built on `:crypto.pbkdf2_hmac/5` from OTP rather than a hashing dependency,
  so the release needs no NIF toolchain on the host. PBKDF2 is the weakest of
  the three algorithms usually recommended (Argon2id and scrypt resist GPU
  attacks better), but it is the strongest one available without adding a
  compiled dependency, and it is an accepted choice at OWASP's iteration count.

  Digests are stored self-describing:

      pbkdf2-sha512$210000$<base64 salt>$<base64 hash>

  so the work factor can be raised later and old digests keep verifying.
  """

  @algorithm "pbkdf2-sha512"
  @digest :sha512
  @default_iterations 210_000
  @salt_bytes 16
  @hash_bytes 64

  @doc """
  Hashes `password`, returning the self-describing digest string.
  """
  def hash(password) when is_binary(password) do
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    iterations = iterations()
    hash = derive(password, salt, iterations)

    Enum.join(
      [@algorithm, iterations, Base.encode64(salt), Base.encode64(hash)],
      "$"
    )
  end

  @doc """
  Verifies `password` against a stored digest in constant time.

  Returns false for a nil or malformed digest, but still spends the same work as
  a real verification so the response time does not reveal whether an account
  exists. Call `no_user_verify/0` on the "no such user" branch for the same
  reason.
  """
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    case decode(stored) do
      {:ok, iterations, salt, expected} ->
        Plug.Crypto.secure_compare(derive(password, salt, iterations), expected)

      :error ->
        no_user_verify()
        false
    end
  end

  def verify(password, _stored) when is_binary(password) do
    no_user_verify()
    false
  end

  def verify(_password, _stored), do: false

  @doc """
  Burns the same time a real verification would take.
  """
  def no_user_verify do
    derive("timing equalisation", :crypto.strong_rand_bytes(@salt_bytes), iterations())
    false
  end

  @doc """
  Whether a stored digest was produced with fewer iterations than we now use,
  meaning it should be rehashed on the next successful login.
  """
  def needs_rehash?(stored) when is_binary(stored) do
    case decode(stored) do
      {:ok, iterations, _salt, _hash} -> iterations < iterations()
      :error -> true
    end
  end

  def needs_rehash?(_stored), do: true

  defp derive(password, salt, iterations) do
    :crypto.pbkdf2_hmac(@digest, password, salt, iterations, @hash_bytes)
  end

  defp decode(stored) do
    with [@algorithm, iterations, salt, hash] <- String.split(stored, "$", parts: 4),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      {:ok, iterations, salt, hash}
    else
      _malformed -> :error
    end
  end

  defp iterations do
    Application.get_env(:micu_poker, :password_iterations, @default_iterations)
  end
end
