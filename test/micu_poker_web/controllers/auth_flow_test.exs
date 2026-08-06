defmodule MicuPokerWeb.AuthFlowTest do
  use MicuPokerWeb.ConnCase, async: false

  alias MicuPoker.Accounts
  alias MicuPoker.RateLimiter

  @password "correct horse battery"

  defp register_account(username) do
    Accounts.register_user(%{
      "username" => username,
      "password" => @password,
      "password_confirmation" => @password
    })
  end

  describe "registration" do
    test "the form renders", %{conn: conn} do
      assert html_response(get(conn, ~p"/register"), 200) =~ "Create account"
    end

    test "a valid submission signs the new account in", %{conn: conn} do
      conn =
        post(conn, ~p"/register", %{
          "user" => %{
            "username" => "Registered",
            "password" => @password,
            "password_confirmation" => @password
          }
        })

      assert redirected_to(conn) == ~p"/lobby"
      assert get_session(conn, :user_token)
      assert conn.assigns.current_user.username == "Registered"
      assert conn.assigns.current_user.is_guest == false
    end

    test "an invalid submission re-renders with errors and no session", %{conn: conn} do
      conn =
        post(conn, ~p"/register", %{
          "user" => %{
            "username" => "x",
            "password" => "short",
            "password_confirmation" => "nope"
          }
        })

      assert html_response(conn, 422) =~ "Create account"
      refute get_session(conn, :user_token)
    end

    test "privileged fields in the form cannot be set by the client", %{conn: conn} do
      conn =
        post(conn, ~p"/register", %{
          "user" => %{
            "username" => "NotRich",
            "password" => @password,
            "password_confirmation" => @password,
            "virtual_chips" => "999999",
            "is_guest" => "true",
            "password_hash" => "injected"
          }
        })

      user = conn.assigns.current_user

      assert user.is_guest == false
      refute user.password_hash == "injected"
      assert user.virtual_chips == Accounts.default_chips()
    end

    test "a guest keeps their identity when they register", %{conn: conn} do
      # Visiting an app route establishes the guest session.
      conn = get(conn, ~p"/lobby")
      guest_id = get_session(conn, :guest_user_id)
      assert guest_id

      conn =
        conn
        |> recycle()
        |> post(~p"/register", %{
          "user" => %{
            "username" => "WasAGuest",
            "password" => @password,
            "password_confirmation" => @password
          }
        })

      assert conn.assigns.current_user.id == guest_id
      assert conn.assigns.current_user.username == "WasAGuest"
      assert conn.assigns.current_user.is_guest == false
    end
  end

  describe "sign in" do
    setup do
      {:ok, user} = register_account("Signer")
      %{user: user}
    end

    test "the form renders", %{conn: conn} do
      assert html_response(get(conn, ~p"/login"), 200) =~ "Sign in"
    end

    test "correct credentials start a session", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "Signer", "password" => @password}})

      assert redirected_to(conn) == ~p"/lobby"
      assert token = get_session(conn, :user_token)
      assert Accounts.get_user_by_session_token(token).id == user.id
    end

    test "wrong credentials answer 401 and start no session", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "Signer", "password" => "wrong pass"}})

      assert html_response(conn, 401) =~ "do not match"
      refute get_session(conn, :user_token)
    end

    test "the error does not reveal whether the username exists", %{conn: conn} do
      known =
        conn
        |> recycle()
        |> post(~p"/login", %{"user" => %{"username" => "Signer", "password" => "wrong pass"}})
        |> html_response(401)

      unknown =
        conn
        |> recycle()
        |> post(~p"/login", %{"user" => %{"username" => "Ghost", "password" => "wrong pass"}})
        |> html_response(401)

      assert known =~ "do not match"
      assert unknown =~ "do not match"
    end

    test "signing in replaces a pre-login guest session", %{conn: conn} do
      conn = get(conn, ~p"/lobby")
      assert get_session(conn, :guest_user_id)

      conn =
        conn
        |> recycle()
        |> post(~p"/login", %{"user" => %{"username" => "Signer", "password" => @password}})

      # Session fixation guard: the old guest id must not survive the sign-in.
      refute get_session(conn, :guest_user_id)
      assert get_session(conn, :user_token)
    end

    test "a return_to path is honoured only when it is a local path", %{conn: conn} do
      local =
        conn
        |> recycle()
        |> post(~p"/login", %{
          "user" => %{"username" => "Signer", "password" => @password, "return_to" => "/docs"}
        })

      assert redirected_to(local) == "/docs"

      external =
        conn
        |> recycle()
        |> post(~p"/login", %{
          "user" => %{
            "username" => "Signer",
            "password" => @password,
            "return_to" => "//evil.example.com/steal"
          }
        })

      assert redirected_to(external) == ~p"/lobby"
    end

    test "a missing password does not raise", %{conn: conn} do
      conn = post(conn, ~p"/login", %{"user" => %{"username" => "Signer"}})

      assert html_response(conn, 401)
    end
  end

  describe "sign out" do
    test "clears the session and revokes the token", %{conn: conn} do
      {:ok, _user} = register_account("Leaver")

      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "Leaver", "password" => @password}})

      token = get_session(conn, :user_token)

      conn = conn |> recycle() |> post(~p"/logout")

      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :user_token)
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "an established account session" do
    test "is used instead of creating a guest", %{conn: conn} do
      {:ok, user} = register_account("Persistent")

      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "Persistent", "password" => @password}})

      conn = conn |> recycle() |> get(~p"/lobby")

      assert conn.assigns.current_user.id == user.id
      refute get_session(conn, :guest_user_id)
    end

    test "a revoked token falls back to a fresh guest", %{conn: conn} do
      {:ok, user} = register_account("Revoked")

      conn =
        post(conn, ~p"/login", %{"user" => %{"username" => "Revoked", "password" => @password}})

      Accounts.delete_all_session_tokens(user)

      conn = conn |> recycle() |> get(~p"/lobby")

      assert conn.assigns.current_user.is_guest
      refute conn.assigns.current_user.id == user.id
    end
  end

  describe "sign-in rate limiting" do
    setup do
      previous = Application.get_env(:micu_poker, :rate_limiting_enabled, true)
      Application.put_env(:micu_poker, :rate_limiting_enabled, true)
      RateLimiter.clear_all()

      on_exit(fn ->
        Application.put_env(:micu_poker, :rate_limiting_enabled, previous)
        RateLimiter.clear_all()
      end)

      {:ok, _user} = register_account("Target")
      :ok
    end

    test "repeated failures from one address are throttled", %{conn: conn} do
      responses =
        for index <- 1..12 do
          conn
          |> recycle()
          |> Map.put(:remote_ip, {203, 0, 113, 40})
          |> post(~p"/login", %{
            "user" => %{"username" => "Target#{index}", "password" => "wrong pass"}
          })
        end

      bodies = Enum.map(responses, & &1.resp_body)

      assert Enum.any?(bodies, &(&1 =~ "Too many"))
    end

    test "a successful sign-in clears the attempt budget", %{conn: conn} do
      for _ <- 1..3 do
        conn
        |> recycle()
        |> Map.put(:remote_ip, {203, 0, 113, 41})
        |> post(~p"/login", %{"user" => %{"username" => "Target", "password" => "wrong pass"}})
      end

      success =
        conn
        |> recycle()
        |> Map.put(:remote_ip, {203, 0, 113, 41})
        |> post(~p"/login", %{"user" => %{"username" => "Target", "password" => @password}})

      assert redirected_to(success) == ~p"/lobby"
      assert RateLimiter.count({:login_user, "target"}, :timer.minutes(15)) == 0
    end
  end
end
