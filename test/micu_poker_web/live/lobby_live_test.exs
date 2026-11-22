defmodule MicuPokerWeb.LobbyLiveTest do
  use MicuPokerWeb.ConnCase

  import Phoenix.LiveViewTest

  alias MicuPoker.Accounts
  alias MicuPoker.Accounts.User
  alias MicuPoker.RateLimiter
  alias MicuPoker.Repo

  test "lobby creates a guest session lazily", %{conn: conn} do
    before_count = Repo.aggregate(User, :count)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ "MicuPoker"
    assert Repo.aggregate(User, :count) == before_count + 1
  end

  test "lobby form labels are connected to their inputs", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ ~s(for="user_username")
    assert html =~ "Display name"
    assert html =~ ~s(for="room_name")
    assert html =~ "Room name"
    assert html =~ ~s(for="room_max_players")
    assert html =~ "Max players"
    assert html =~ ~s(for="room_starting_chips")
    assert html =~ "Starting chips"
    assert html =~ ~s(for="room_small_blind")
    assert html =~ "Small blind"
    assert html =~ ~s(for="room_big_blind")
    assert html =~ "Big blind"
  end

  test "lobby form uses configured table defaults", %{conn: conn} do
    with_env(%{
      "DEFAULT_STARTING_CHIPS" => "1500",
      "DEFAULT_SMALL_BLIND" => "15",
      "DEFAULT_BIG_BLIND" => "30"
    })

    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)

    {:ok, _view, html} = live(conn, ~p"/lobby")

    assert html =~ ~s(name="room[starting_chips]")
    assert html =~ ~s(value="1500")
    assert html =~ ~s(name="room[small_blind]")
    assert html =~ ~s(value="15")
    assert html =~ ~s(name="room[big_blind]")
    assert html =~ ~s(value="30")
  end

  test "lobby rate limits rapid room creation over LiveView websocket", %{conn: conn} do
    previous = Application.get_env(:micu_poker, :rate_limiting_enabled, true)
    Application.put_env(:micu_poker, :rate_limiting_enabled, true)
    RateLimiter.clear_all()

    on_exit(fn ->
      Application.put_env(:micu_poker, :rate_limiting_enabled, previous)
      RateLimiter.clear_all()
    end)

    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/lobby")

    # 22 > 2 * limit (10), so even across a 60s fixed-window boundary it is
    # guaranteed to trigger the per-user room creation rate limiter.
    results =
      for idx <- 1..22 do
        render_submit(view, :create_room, %{
          "room" => %{
            "name" => "Spam Room #{idx}",
            "max_players" => "6",
            "starting_chips" => "1000",
            "small_blind" => "10",
            "big_blind" => "10"
          }
        })
      end

    assert Enum.any?(results, fn html -> is_binary(html) and html =~ "too quickly" end)
  end

  test "lobby supports fictional currency selector, stake presets, and table search", %{
    conn: conn
  } do
    {:ok, user} = Accounts.create_guest_user()

    {:ok, _ron_room} =
      MicuPoker.Rooms.create_room(
        %{"name" => "Bucharest Lounge", "currency" => "FIC-RON"},
        user.id
      )

    {:ok, _gold_room} =
      MicuPoker.Rooms.create_room(
        %{"name" => "Royal Vault", "currency" => "GOLD"},
        user.id
      )

    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)
    {:ok, view, html} = live(conn, ~p"/lobby")

    assert html =~ "Fictional currency (play only)"
    assert html =~ "FIC-RON"
    assert html =~ "Bucharest Lounge"
    assert html =~ "Royal Vault"

    # Search by currency code
    filtered = render_change(view, :search, %{"q" => "FIC-RON"})
    assert filtered =~ "Bucharest Lounge"
    refute filtered =~ "Royal Vault"

    # Stake preset updates form values
    preset_html = render_click(view, :stake_preset, %{"preset" => "high"})
    assert preset_html =~ ~s(value="20000")

    # Creating a room broadcasts a live PubSub update to connected lobby views
    {:ok, _live_room} =
      MicuPoker.Rooms.create_room(
        %{"name" => "Live Broadcast Table", "currency" => "FIC-RON"},
        user.id
      )

    assert render(view) =~ "Live Broadcast Table"
  end

  test "quick_practice launches an instant practice table with AI bots", %{conn: conn} do
    {:ok, user} = Accounts.create_guest_user()
    conn = Plug.Test.init_test_session(conn, guest_user_id: user.id)
    {:ok, view, _html} = live(conn, ~p"/lobby")

    assert {:error, {:live_redirect, %{to: "/rooms/" <> room_id_str}}} =
             render_click(view, :quick_practice, %{"bots" => "2"})

    room_id = String.to_integer(room_id_str)
    state = MicuPoker.Poker.TableServer.state(room_id, user.id)
    assert length(state.players) == 3
    assert Enum.count(state.players, & &1.is_bot) == 2
  end

  defp with_env(values) do
    previous = Map.new(values, fn {key, _value} -> {key, System.get_env(key)} end)

    Enum.each(values, fn {key, value} -> System.put_env(key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)
  end
end
