defmodule MicuPokerWeb.TableChannelTest do
  use MicuPoker.DataCase

  alias MicuPoker.Accounts
  alias MicuPokerWeb.TableChannel

  test "rejects invalid table topics without raising" do
    {:ok, user} = Accounts.create_guest_user()
    socket = %Phoenix.Socket{assigns: %{user_id: user.id}}

    assert {:error, %{reason: "room_not_found"}} =
             TableChannel.join("table:not-a-number", %{}, socket)

    assert {:error, %{reason: "room_not_found"}} =
             TableChannel.join("table:999999999", %{}, socket)
  end

  test "rejects malformed inbound events without raising" do
    {:ok, user} = Accounts.create_guest_user()
    socket = %Phoenix.Socket{assigns: %{user_id: user.id, room_id: 123}}

    assert {:reply, {:error, %{reason: "invalid_payload"}}, ^socket} =
             TableChannel.handle_in("action", %{}, socket)

    assert {:reply, {:error, %{reason: "invalid_payload"}}, ^socket} =
             TableChannel.handle_in("chat", %{}, socket)

    assert {:reply, {:error, %{reason: "unknown_event"}}, ^socket} =
             TableChannel.handle_in("wat", %{}, socket)
  end
end
