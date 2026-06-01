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
end
