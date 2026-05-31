defmodule MicuPokerWeb.UserSocketTest do
  use ExUnit.Case, async: true

  alias MicuPokerWeb.UserSocket

  test "rejects query-param user id impersonation without session" do
    assert :error = UserSocket.connect(%{"user_id" => "123"}, %Phoenix.Socket{}, %{})
  end

  test "uses signed socket token" do
    token = Phoenix.Token.sign(MicuPokerWeb.Endpoint, "user socket", 321)

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    assert socket.assigns.user_id == 321
  end

  test "rejects invalid socket token" do
    assert :error = UserSocket.connect(%{"token" => "not-valid"}, %Phoenix.Socket{}, %{})
  end

  test "uses guest user id from the signed session" do
    assert {:ok, socket} =
             UserSocket.connect(%{"user_id" => "999"}, %Phoenix.Socket{}, %{
               session: %{"guest_user_id" => 123}
             })

    assert socket.assigns.user_id == 123
    assert UserSocket.id(socket) == "guest:123"
  end

  test "accepts atom session keys from socket connect info" do
    assert {:ok, socket} =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{session: %{guest_user_id: 456}})

    assert socket.assigns.user_id == 456
    assert UserSocket.id(socket) == "guest:456"
  end
end
