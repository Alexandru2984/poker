defmodule MicuPokerWeb.RoomAccessTest do
  use MicuPokerWeb.ConnCase, async: false

  import Phoenix.ChannelTest, except: [connect: 3]
  import Phoenix.LiveViewTest

  alias MicuPoker.Accounts
  alias MicuPoker.Poker.TableServer
  alias MicuPoker.Rooms

  @endpoint MicuPokerWeb.Endpoint
  @room_password "table-secret"

  setup do
    {:ok, host} = Accounts.create_guest_user()

    {:ok, room} =
      Rooms.create_room(
        %{
          "name" => "Private Table",
          "max_players" => "6",
          "small_blind" => "5",
          "big_blind" => "10",
          "starting_chips" => "1000",
          "password" => @room_password
        },
        host.id
      )

    %{room: room, host: host}
  end

  describe "browser access to a private table" do
    test "an outsider is sent to the password prompt", %{conn: conn, room: room} do
      conn = get(conn, ~p"/rooms/#{room.id}")

      assert redirected_to(conn) == ~p"/rooms/#{room.id}/unlock"
    end

    test "the prompt does not leak the password or its hash", %{conn: conn, room: room} do
      body = conn |> get(~p"/rooms/#{room.id}/unlock") |> html_response(200)

      refute body =~ @room_password
      refute body =~ "pbkdf2"
    end

    test "a wrong password is refused", %{conn: conn, room: room} do
      conn =
        post(conn, ~p"/rooms/#{room.id}/unlock", %{"room" => %{"password" => "not-it"}})

      assert html_response(conn, 401) =~ "not correct"
      refute get_session(conn, :unlocked_rooms)
    end

    test "the right password grants access for the session", %{conn: conn, room: room} do
      conn =
        post(conn, ~p"/rooms/#{room.id}/unlock", %{"room" => %{"password" => @room_password}})

      assert redirected_to(conn) == ~p"/rooms/#{room.id}"
      assert room.id in get_session(conn, :unlocked_rooms)

      assert {:ok, _view, _html} = conn |> recycle() |> live(~p"/rooms/#{room.id}")
    end

    test "a grant for one table does not open another", %{conn: conn, room: room, host: host} do
      {:ok, other} =
        Rooms.create_room(
          %{"name" => "Other Private", "password" => @room_password},
          host.id
        )

      conn =
        post(conn, ~p"/rooms/#{room.id}/unlock", %{"room" => %{"password" => @room_password}})

      assert redirected_to(conn |> recycle() |> get(~p"/rooms/#{other.id}")) ==
               ~p"/rooms/#{other.id}/unlock"
    end

    test "POST join is refused without a grant", %{conn: conn, room: room} do
      conn = post(conn, ~p"/rooms/#{room.id}/join")

      assert redirected_to(conn) == ~p"/rooms/#{room.id}/unlock"
      refute Rooms.seated?(room.id, conn.assigns.current_user.id)
    end

    test "the host never needs their own password", %{conn: conn, room: room, host: host} do
      conn = Plug.Test.init_test_session(conn, guest_user_id: host.id)

      assert {:ok, _view, _html} = live(conn, ~p"/rooms/#{room.id}")
    end

    test "a public table needs no unlock at all", %{conn: conn, host: host} do
      {:ok, public} = Rooms.create_room(%{"name" => "Open Table"}, host.id)

      assert {:ok, _view, _html} = live(conn, ~p"/rooms/#{public.id}")
    end
  end

  describe "channel access to a private table" do
    test "a player with no seat is rejected", %{room: room} do
      {:ok, outsider} = Accounts.create_guest_user()
      start_supervised!({TableServer, room.id})

      {:ok, socket} =
        Phoenix.ChannelTest.connect(MicuPokerWeb.UserSocket, %{},
          connect_info: %{session: %{"guest_user_id" => outsider.id}}
        )

      assert {:error, %{reason: "room_locked"}} =
               subscribe_and_join(socket, MicuPokerWeb.TableChannel, "table:#{room.id}")
    end

    test "a player who already holds a seat is admitted", %{room: room} do
      {:ok, player} = Accounts.create_guest_user()
      start_supervised!({TableServer, room.id})

      # A seat can only have been obtained by passing the password over HTTP.
      {:ok, _room_player} = Rooms.seat_user(room, player.id)

      {:ok, socket} =
        Phoenix.ChannelTest.connect(MicuPokerWeb.UserSocket, %{},
          connect_info: %{session: %{"guest_user_id" => player.id}}
        )

      assert {:ok, _reply, _channel} =
               subscribe_and_join(socket, MicuPokerWeb.TableChannel, "table:#{room.id}")
    end

    test "the host is admitted without a seat", %{room: room, host: host} do
      start_supervised!({TableServer, room.id})

      {:ok, socket} =
        Phoenix.ChannelTest.connect(MicuPokerWeb.UserSocket, %{},
          connect_info: %{session: %{"guest_user_id" => host.id}}
        )

      assert {:ok, _reply, _channel} =
               subscribe_and_join(socket, MicuPokerWeb.TableChannel, "table:#{room.id}")
    end
  end
end
