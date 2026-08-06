defmodule MicuPokerWeb.UserSocketTest do
  use MicuPoker.DataCase, async: true

  alias MicuPoker.Accounts
  alias MicuPokerWeb.UserSocket

  setup do
    {:ok, user} = Accounts.create_guest_user()
    %{user: user}
  end

  test "rejects query-param user id impersonation without session" do
    assert :error = UserSocket.connect(%{"user_id" => "123"}, %Phoenix.Socket{}, %{})
  end

  test "uses signed socket token", %{user: user} do
    token = UserSocket.sign_token(user.id)

    assert {:ok, socket} = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
    assert socket.assigns.user_id == user.id
  end

  test "rejects invalid socket token" do
    assert :error = UserSocket.connect(%{"token" => "not-valid"}, %Phoenix.Socket{}, %{})
  end

  test "rejects a valid token whose user no longer exists", %{user: user} do
    token = UserSocket.sign_token(user.id)
    Repo.delete!(user)

    assert :error = UserSocket.connect(%{"token" => token}, %Phoenix.Socket{}, %{})
  end

  test "uses guest user id from the signed session", %{user: user} do
    assert {:ok, socket} =
             UserSocket.connect(%{"user_id" => "999"}, %Phoenix.Socket{}, %{
               session: %{"guest_user_id" => user.id}
             })

    assert socket.assigns.user_id == user.id
    assert UserSocket.id(socket) == "user_socket:#{user.id}"
  end

  test "accepts atom session keys from socket connect info", %{user: user} do
    assert {:ok, socket} =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{session: %{guest_user_id: user.id}})

    assert socket.assigns.user_id == user.id
  end

  test "rejects a session pointing at a user that was cleaned up", %{user: user} do
    Repo.delete!(user)

    assert :error =
             UserSocket.connect(%{}, %Phoenix.Socket{}, %{session: %{guest_user_id: user.id}})
  end
end
