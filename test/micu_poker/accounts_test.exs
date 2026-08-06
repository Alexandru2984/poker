defmodule MicuPoker.AccountsTest do
  use MicuPoker.DataCase, async: true

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.{Password, User}

  @password "correct horse battery"

  defp register(attrs \\ %{}) do
    Accounts.register_user(
      Map.merge(
        %{
          "username" => "player#{System.unique_integer([:positive])}",
          "password" => @password,
          "password_confirmation" => @password
        },
        attrs
      )
    )
  end

  describe "password hashing" do
    test "a digest never contains the password" do
      digest = Password.hash(@password)

      refute digest =~ @password
      assert digest =~ "pbkdf2-sha512$"
    end

    test "the same password hashes differently every time" do
      refute Password.hash(@password) == Password.hash(@password)
    end

    test "verification accepts the right password and rejects others" do
      digest = Password.hash(@password)

      assert Password.verify(@password, digest)
      refute Password.verify("wrong password", digest)
      refute Password.verify("", digest)
    end

    test "verification of a malformed or missing digest fails safely" do
      refute Password.verify(@password, "not-a-digest")
      refute Password.verify(@password, "pbkdf2-sha512$abc$def")
      refute Password.verify(@password, nil)
      refute Password.verify(nil, Password.hash(@password))
    end

    test "a digest below the current work factor is flagged for rehashing" do
      weak = Application.get_env(:micu_poker, :password_iterations)
      Application.put_env(:micu_poker, :password_iterations, 500)
      digest = Password.hash(@password)
      Application.put_env(:micu_poker, :password_iterations, weak)

      assert Password.needs_rehash?(digest)
      refute Password.needs_rehash?(Password.hash(@password))
    end
  end

  describe "register_user/1" do
    test "creates a non-guest account" do
      assert {:ok, user} = register(%{"username" => "Micu"})

      assert user.username == "Micu"
      assert user.is_guest == false
      assert is_binary(user.password_hash)
    end

    test "the plaintext password is not retained on the struct" do
      assert {:ok, user} = register()

      assert user.password == nil
      assert user.password_confirmation == nil
    end

    test "requires a matching confirmation" do
      assert {:error, changeset} =
               register(%{"password_confirmation" => "something else entirely"})

      assert %{password_confirmation: ["does not match"]} = errors_on(changeset)
    end

    test "requires a password of reasonable length" do
      assert {:error, changeset} =
               register(%{"password" => "short", "password_confirmation" => "short"})

      assert %{password: [_message | _]} = errors_on(changeset)
    end

    test "rejects a repetitive password of legal length" do
      repetitive = String.duplicate("ab", 8)

      assert {:error, changeset} =
               register(%{"password" => repetitive, "password_confirmation" => repetitive})

      assert %{password: [message | _]} = errors_on(changeset)
      assert message =~ "repetitive"
    end

    test "rejects a username that impersonates a generated guest" do
      assert {:error, changeset} = register(%{"username" => "Guest-abcd1234"})

      assert %{username: [message | _]} = errors_on(changeset)
      assert message =~ "Guest-"
    end

    test "usernames are unique regardless of case" do
      assert {:ok, _user} = register(%{"username" => "Micu"})
      assert {:error, changeset} = register(%{"username" => "MICU"})

      assert %{username: [_message | _]} = errors_on(changeset)
    end

    test "an invalid email is rejected but a blank one is allowed" do
      assert {:error, changeset} = register(%{"email" => "not-an-email"})
      assert %{email: [_message | _]} = errors_on(changeset)

      assert {:ok, user} = register(%{"email" => ""})
      assert user.email == nil
    end

    test "emails are stored lowercased" do
      assert {:ok, user} = register(%{"email" => "  Micu@Example.COM "})

      assert user.email == "micu@example.com"
    end
  end

  describe "authenticate/2" do
    setup do
      {:ok, user} = register(%{"username" => "Authentic"})
      %{user: user}
    end

    test "returns the user for the right credentials", %{user: user} do
      assert %User{id: id} = Accounts.authenticate("Authentic", @password)
      assert id == user.id
    end

    test "the username comparison is case-insensitive" do
      assert %User{} = Accounts.authenticate("AUTHENTIC", @password)
      assert %User{} = Accounts.authenticate("  authentic  ", @password)
    end

    test "rejects a wrong password" do
      refute Accounts.authenticate("Authentic", "wrong password entirely")
    end

    test "rejects an unknown username" do
      refute Accounts.authenticate("nobody-here", @password)
    end

    test "a guest account can never be signed into" do
      {:ok, guest} = Accounts.create_guest_user()

      refute Accounts.authenticate(guest.username, @password)
      refute Accounts.authenticate(guest.username, "")
    end

    test "rejects non-string input without raising" do
      refute Accounts.authenticate(nil, nil)
      refute Accounts.authenticate(%{}, [])
    end

    test "a digest below the current work factor is upgraded on success" do
      Application.put_env(:micu_poker, :password_iterations, 500)
      {:ok, user} = register(%{"username" => "Upgradable"})
      weak_digest = user.password_hash

      Application.put_env(:micu_poker, :password_iterations, 1_000)
      on_exit(fn -> Application.put_env(:micu_poker, :password_iterations, 1_000) end)

      assert %User{} = Accounts.authenticate("Upgradable", @password)

      assert Repo.reload(user).password_hash != weak_digest
      assert %User{} = Accounts.authenticate("Upgradable", @password)
    end
  end

  describe "upgrade_guest/2" do
    test "keeps the same row so history stays attached" do
      {:ok, guest} = Accounts.create_guest_user()

      assert {:ok, user} =
               Accounts.upgrade_guest(guest, %{
                 "username" => "Upgraded",
                 "password" => @password,
                 "password_confirmation" => @password
               })

      assert user.id == guest.id
      assert user.is_guest == false
      assert %User{} = Accounts.authenticate("Upgraded", @password)
    end

    test "refuses to re-register an existing account" do
      {:ok, account} = register()

      assert {:error, changeset} =
               Accounts.upgrade_guest(account, %{
                 "username" => "Whatever",
                 "password" => @password,
                 "password_confirmation" => @password
               })

      assert %{username: [_message | _]} = errors_on(changeset)
    end
  end

  describe "session tokens" do
    setup do
      {:ok, user} = register()
      %{user: user, token: Accounts.generate_session_token(user)}
    end

    test "a token resolves back to its user", %{user: user, token: token} do
      assert %User{id: id} = Accounts.get_user_by_session_token(token)
      assert id == user.id
    end

    test "the database stores only a digest of the token", %{token: token} do
      stored = Repo.one!(MicuPoker.Accounts.UserToken)

      assert stored.token == :crypto.hash(:sha256, token)
      refute stored.token == token
    end

    test "an unknown or malformed token resolves to nobody" do
      refute Accounts.get_user_by_session_token(:crypto.strong_rand_bytes(32))
      refute Accounts.get_user_by_session_token("")
      refute Accounts.get_user_by_session_token(nil)
    end

    test "deleting a token revokes it", %{token: token} do
      assert :ok = Accounts.delete_session_token(token)
      refute Accounts.get_user_by_session_token(token)
    end

    test "signing out everywhere revokes every token", %{user: user, token: token} do
      other = Accounts.generate_session_token(user)

      assert :ok = Accounts.delete_all_session_tokens(user)
      refute Accounts.get_user_by_session_token(token)
      refute Accounts.get_user_by_session_token(other)
    end

    test "deleting a user cascades to their tokens", %{user: user, token: token} do
      Repo.delete!(user)

      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "guest cleanup" do
    test "removes unused guests but never registered accounts" do
      {:ok, guest} = Accounts.create_guest_user()
      {:ok, account} = register()

      past = DateTime.add(DateTime.utc_now(:second), -1, :day)

      for user <- [guest, account],
          do: Repo.update!(Ecto.Changeset.change(user, inserted_at: past))

      cutoff = DateTime.add(DateTime.utc_now(:second), -1, :hour)
      assert {:ok, count} = Accounts.delete_unused_guest_users(cutoff)

      assert count >= 1
      refute Repo.reload(guest)
      assert Repo.reload(account)
    end
  end
end
